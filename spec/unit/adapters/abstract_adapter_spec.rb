# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../lib/apartment/adapters/abstract_adapter'
require_relative '../../../lib/apartment/concerns/model'

# Concrete test subclass that implements protected abstract methods.
class TestAdapter < Apartment::Adapters::AbstractAdapter
  attr_reader :created_tenants, :dropped_tenants

  def initialize(config)
    super
    @created_tenants = []
    @dropped_tenants = []
  end

  def resolve_connection_config(tenant, base_config: nil)
    config = base_config || { 'adapter' => 'postgresql', 'database' => tenant }
    config.merge('database' => tenant)
  end

  protected

  def create_tenant(tenant)
    @created_tenants << tenant
  end

  def drop_tenant(tenant)
    @dropped_tenants << tenant
  end
end

# Minimal ActiveRecord stub for migrate tests.
unless defined?(ActiveRecord::Base)
  module ActiveRecord
    class Base
      def self.connection_pool
        raise('stub: override with allow in tests')
      end
    end
  end
end

# Tagged :isolate_pinned_models — the #process_pinned_models specs are
# count-sensitive, and Apartment.pinned_models is a process-lifetime registry
# (clear_config keeps it). The spec_helper hook gives each example a clean
# registry; see spec/CLAUDE.md.
RSpec.describe(Apartment::Adapters::AbstractAdapter, :isolate_pinned_models) do
  let(:connection_config) { { adapter: 'postgresql', host: 'localhost' } }
  let(:adapter) { TestAdapter.new(connection_config) }

  before do
    Apartment.configure do |c|
      c.tenant_strategy = :schema
      c.tenants_provider = -> { %w[t1 t2] }
      c.default_tenant = 'public'
      c.schema_load_strategy = nil # disable by default in tests (explicit in schema loading tests)
    end
  end

  # Helper: reconfigure Apartment with overrides (Config is frozen after configure,
  # so we must reconfigure rather than stub individual accessors).
  def reconfigure(**overrides)
    Apartment.configure do |c|
      c.tenant_strategy = :schema
      c.tenants_provider = -> { %w[t1 t2] }
      c.default_tenant = 'public'
      overrides.each { |key, val| c.send(:"#{key}=", val) }
    end
  end

  describe '#initialize' do
    it 'stores the connection_config' do
      expect(adapter.connection_config).to(eq(connection_config))
    end
  end

  describe '#validated_connection_config' do
    it 'returns the resolved config for valid tenant names' do
      result = adapter.validated_connection_config('acme')
      expect(result).to(eq('adapter' => 'postgresql', 'database' => 'acme', 'host' => 'localhost'))
    end

    it 'raises ConfigurationError for invalid tenant names' do
      expect { adapter.validated_connection_config("bad\x00name") }
        .to(raise_error(Apartment::ConfigurationError, /NUL byte/))
    end

    it 'raises ConfigurationError for empty tenant names' do
      expect { adapter.validated_connection_config('') }
        .to(raise_error(Apartment::ConfigurationError, /cannot be empty/))
    end

    it 'falls back to base_config when base_config_override is nil' do
      result = adapter.validated_connection_config('acme', base_config_override: nil)
      expect(result).to(eq('adapter' => 'postgresql', 'database' => 'acme', 'host' => 'localhost'))
    end

    context 'tenant_pool_size' do
      it 'does not inject a pool size when tenant_pool_size is nil (inherit base pool)' do
        reconfigure(tenant_pool_size: nil)
        result = adapter.validated_connection_config('acme')
        expect(result).not_to(have_key('pool'))
      end

      it 'injects pool when tenant_pool_size is set' do
        reconfigure(tenant_pool_size: 3)
        result = adapter.validated_connection_config('acme')
        expect(result).to(include('pool' => 3))
      end

      it 'overrides a pool size carried by the base config' do
        reconfigure(tenant_pool_size: 2)
        result = adapter.validated_connection_config(
          'acme', base_config_override: { 'adapter' => 'postgresql', 'pool' => 25 }
        )
        expect(result).to(include('pool' => 2))
      end
    end

    context 'physical-name validation (pool-resolution path)' do
      # validated_connection_config validates the *physical* tenant identifier
      # (the database name for database-per-tenant strategies) — the
      # environmentified name in the base adapter, matching what create uses.
      # Regression guard: it previously validated the raw tenant, so an invalid
      # environmentified name slipped through pool resolution.
      it 'validates the environmentified name, not the raw tenant' do
        reconfigure(environmentify_strategy: ->(t) { "#{t}\x00" })
        expect { adapter.validated_connection_config('acme') }
          .to(raise_error(Apartment::ConfigurationError, /NUL byte/))
      end
    end
  end

  describe '#resolve_connection_config' do
    it 'raises NotImplementedError on the abstract class' do
      abstract = described_class.new(connection_config)
      expect { abstract.resolve_connection_config('t1') }.to(raise_error(NotImplementedError))
    end

    it 'returns a config hash in the concrete subclass' do
      expect(adapter.resolve_connection_config('t1')).to(eq('adapter' => 'postgresql', 'database' => 't1'))
    end
  end

  describe '#create' do
    it 'delegates to create_tenant' do
      allow(Apartment::Instrumentation).to(receive(:instrument))
      adapter.create('acme')
      expect(adapter.created_tenants).to(eq(['acme']))
    end

    it 'instruments the create event' do
      expect(Apartment::Instrumentation).to(receive(:instrument).with(:create, tenant: 'acme'))
      adapter.create('acme')
    end

    it 'raises ConfigurationError for invalid tenant names before creating' do
      allow(Apartment::Instrumentation).to(receive(:instrument))
      expect { adapter.create("bad\x00name") }
        .to(raise_error(Apartment::ConfigurationError, /NUL byte/))
      # Should not have called create_tenant
      expect(adapter.created_tenants).to(be_empty)
    end

    it 'validates the environmentified name, not just the raw name' do
      # Raw name is 59 chars (valid for PG 63 limit), but "test_" prefix makes 64 (exceeds 63)
      reconfigure(environmentify_strategy: :prepend)
      allow(Rails).to(receive(:env).and_return('test'))
      allow(Apartment::Instrumentation).to(receive(:instrument))

      tenant = 'a' * 59
      expect { adapter.create(tenant) }
        .to(raise_error(Apartment::ConfigurationError, /too long.*64.*max 63/))
      expect(adapter.created_tenants).to(be_empty)
    end

    it 'rejects a pool-key-unsafe raw tenant on create even if environmentify_strategy strips it' do
      reconfigure(environmentify_strategy: ->(t) { t.tr(':', '_') })
      allow(Apartment::Instrumentation).to(receive(:instrument))
      expect { adapter.create('acme:eu') }
        .to(raise_error(Apartment::ConfigurationError, /colon/))
      expect(adapter.created_tenants).to(be_empty)
    end

    it 'runs :create callbacks around the operation' do
      callback_log = []

      TestAdapter.set_callback(:create, :before) { callback_log << :before }
      TestAdapter.set_callback(:create, :after) { callback_log << :after }

      allow(Apartment::Instrumentation).to(receive(:instrument))
      adapter.create('acme')

      expect(callback_log).to(eq(%i[before after]))
    ensure
      TestAdapter.reset_callbacks(:create)
    end
  end

  describe '#drop' do
    let(:pool_manager) { Apartment.pool_manager }

    it 'delegates to drop_tenant' do
      allow(Apartment::Instrumentation).to(receive(:instrument))
      adapter.drop('acme')
      expect(adapter.dropped_tenants).to(eq(['acme']))
    end

    it 'removes all role-variant pools via remove_tenant on PoolManager' do
      allow(Apartment::Instrumentation).to(receive(:instrument))
      allow(Apartment).to(receive(:deregister_shard))
      expect(pool_manager).to(receive(:remove_tenant).with('acme').and_return([]))
      adapter.drop('acme')
    end

    it 'disconnects each pool returned by remove_tenant' do
      mock_pool = double('Pool', disconnect!: true)
      allow(pool_manager).to(receive(:remove_tenant).and_return([['acme:primary', mock_pool]]))
      allow(Apartment).to(receive(:deregister_shard))
      allow(Apartment::Instrumentation).to(receive(:instrument))

      expect(mock_pool).to(receive(:disconnect!))
      adapter.drop('acme')
    end

    it 'does not call disconnect! if pool does not respond to it' do
      mock_pool = double('Pool')
      allow(pool_manager).to(receive(:remove_tenant).and_return([['acme:primary', mock_pool]]))
      allow(Apartment).to(receive(:deregister_shard))
      allow(Apartment::Instrumentation).to(receive(:instrument))

      # Should not raise
      adapter.drop('acme')
    end

    it 'instruments the drop event' do
      allow(pool_manager).to(receive(:remove_tenant).and_return([]))
      allow(Apartment).to(receive(:deregister_shard))
      expect(Apartment::Instrumentation).to(receive(:instrument).with(:drop, tenant: 'acme'))
      adapter.drop('acme')
    end

    it 'deregisters each pool_key from AR ConnectionHandler' do
      mock_pool = double('Pool', disconnect!: true)
      removed = [['acme:primary', mock_pool], ['acme:replica', mock_pool]]
      allow(pool_manager).to(receive(:remove_tenant).and_return(removed))
      allow(Apartment::Instrumentation).to(receive(:instrument))

      expect(Apartment).to(receive(:deregister_shard).with('acme:primary'))
      expect(Apartment).to(receive(:deregister_shard).with('acme:replica'))
      adapter.drop('acme')
    end

    it 'still deregisters shard and instruments when disconnect! raises' do
      mock_pool = double('Pool')
      allow(mock_pool).to(receive(:respond_to?).with(:disconnect!).and_return(true))
      allow(mock_pool).to(receive(:disconnect!).and_raise(RuntimeError, 'disconnect boom'))
      allow(pool_manager).to(receive(:remove_tenant).and_return([['acme:primary', mock_pool]]))

      expect(Apartment).to(receive(:deregister_shard).with('acme:primary'))
      expect(Apartment::Instrumentation).to(receive(:instrument).with(:drop, tenant: 'acme'))

      adapter.drop('acme')
    end

    it 'handles nil pool_manager gracefully' do
      allow(Apartment).to(receive(:pool_manager).and_return(nil))
      allow(Apartment::Instrumentation).to(receive(:instrument))

      # Should not raise even without a pool_manager
      expect { adapter.drop('acme') }.not_to(raise_error)
    end
  end

  describe '#migrate' do
    it 'sets Current.tenant during the migration block' do
      tenant_during_migrate = nil
      migration_context = double('MigrationContext')
      connection_pool = double('ConnectionPool', migration_context: migration_context)

      allow(ActiveRecord::Base).to(receive(:connection_pool).and_return(connection_pool))
      allow(migration_context).to(receive(:migrate) { tenant_during_migrate = Apartment::Current.tenant })

      adapter.migrate('acme')
      expect(tenant_during_migrate).to(eq('acme'))
    end

    it 'switches tenant and runs migrations' do
      migration_context = double('MigrationContext')
      connection_pool = double('ConnectionPool', migration_context: migration_context)

      allow(ActiveRecord::Base).to(receive(:connection_pool).and_return(connection_pool))
      expect(migration_context).to(receive(:migrate).with(nil))

      adapter.migrate('acme')
    end

    it 'passes version to migrate' do
      migration_context = double('MigrationContext')
      connection_pool = double('ConnectionPool', migration_context: migration_context)

      allow(ActiveRecord::Base).to(receive(:connection_pool).and_return(connection_pool))
      expect(migration_context).to(receive(:migrate).with(20_260_101_000_000))

      adapter.migrate('acme', 20_260_101_000_000)
    end

    it 'restores tenant context after migration' do
      migration_context = double('MigrationContext', migrate: true)
      connection_pool = double('ConnectionPool', migration_context: migration_context)
      allow(ActiveRecord::Base).to(receive(:connection_pool).and_return(connection_pool))

      Apartment::Current.tenant = 'original'
      adapter.migrate('acme')
      expect(Apartment::Current.tenant).to(eq('original'))
    end
  end

  describe '#seed' do
    it 'sets Current.tenant during the seed block' do
      tenant_during_seed = nil
      reconfigure(seed_data_file: '/tmp/seeds.rb')
      allow(File).to(receive(:exist?).with('/tmp/seeds.rb').and_return(true))
      allow(adapter).to(receive(:load) { tenant_during_seed = Apartment::Current.tenant })

      adapter.seed('acme')
      expect(tenant_during_seed).to(eq('acme'))
    end

    it 'switches tenant and loads the seed file' do
      reconfigure(seed_data_file: '/tmp/seeds.rb')
      allow(File).to(receive(:exist?).with('/tmp/seeds.rb').and_return(true))
      expect(adapter).to(receive(:load).with('/tmp/seeds.rb'))

      adapter.seed('acme')
    end

    it 'does nothing when seed_data_file is nil' do
      # Default config has seed_data_file = nil
      expect(adapter).not_to(receive(:load))

      adapter.seed('acme')
    end

    it 'raises ConfigurationError when seed file does not exist' do
      reconfigure(seed_data_file: '/tmp/missing.rb')
      allow(File).to(receive(:exist?).with('/tmp/missing.rb').and_return(false))

      expect { adapter.seed('acme') }.to(raise_error(
                                           Apartment::ConfigurationError,
                                           "Seed file '/tmp/missing.rb' does not exist"
                                         ))
    end
  end

  describe '#shared_pinned_connection?' do
    it 'returns false by default (safe fallback)' do
      expect(adapter.shared_pinned_connection?).to(be(false))
    end
  end

  describe '#pinned_table_qualifier' do
    it 'raises NotImplementedError on the abstract class' do
      expect { adapter.pinned_table_qualifier }.to(
        raise_error(NotImplementedError, /pinned_table_qualifier must be implemented/)
      )
    end
  end

  describe '#qualify_pinned_table_name' do
    it 'raises NotImplementedError when the subclass supplies no qualifier' do
      klass = Class.new(ActiveRecord::Base) { include Apartment::Model }
      stub_const('AbstractQualified', klass)

      expect { adapter.qualify_pinned_table_name(klass) }.to(
        raise_error(NotImplementedError, /pinned_table_qualifier must be implemented/)
      )
    end
  end

  # The warning walks the whole pinned registry, which is process-lifetime and
  # leaks across examples — a model pinned by an earlier example could emit a
  # warning here and break the "stays quiet" assertions depending on order.
  describe '#warn_unregistered_pinned_subclasses', :isolate_pinned_models do
    # The transitional STI-migration shape: a subclass declaring its own table
    # inherits the pin flag but no qualification, so it silently reads the
    # wrong tenant's table. Detection is descendants-based (complete under
    # eager loading), so this warns rather than raising.
    it 'warns about a subclass that declares its own table and is unregistered' do
      parent = Class.new(ActiveRecord::Base) do
        self.table_name = 'warn_parents'
        include Apartment::Model
      end
      stub_const('WarnParent', parent)
      parent.pin_tenant
      child = Class.new(parent) { self.table_name = 'warn_children' }
      stub_const('WarnChild', child)

      expect { adapter.send(:warn_unregistered_pinned_subclasses) }
        .to(output(/WarnChild inherits a pin from WarnParent/).to_stderr)
    end

    it 'stays quiet for an STI child sharing the parent table' do
      parent = Class.new(ActiveRecord::Base) do
        self.table_name = 'quiet_parents'
        include Apartment::Model
      end
      stub_const('QuietParent', parent)
      parent.pin_tenant
      stub_const('QuietChild', Class.new(parent))

      expect { adapter.send(:warn_unregistered_pinned_subclasses) }.not_to(output.to_stderr)
    end

    # descendants is transitive, so two pinned classes in one chain both see the
    # same unregistered descendant. Reporting it once per pinned ancestor buries
    # the single corrective action under duplicates naming different ancestors.
    it 'warns once when several pinned ancestors share a descendant' do
      parent = Class.new(ActiveRecord::Base) do
        self.table_name = 'dup_parents'
        include Apartment::Model
      end
      stub_const('DupParent', parent)
      parent.pin_tenant
      mid = Class.new(parent) do
        self.table_name = 'dup_mids'
        include Apartment::Model
      end
      stub_const('DupMid', mid)
      mid.pin_tenant
      stub_const('DupChild', Class.new(mid) { self.table_name = 'dup_children' })

      warnings = []
      allow(adapter).to(receive(:warn) { |msg| warnings << msg })

      adapter.send(:warn_unregistered_pinned_subclasses)

      expect(warnings.grep(/DupChild/).size).to(eq(1))
    end

    it 'names the nearest pinned ancestor' do
      parent = Class.new(ActiveRecord::Base) do
        self.table_name = 'near_parents'
        include Apartment::Model
      end
      stub_const('NearParent', parent)
      parent.pin_tenant
      mid = Class.new(parent) do
        self.table_name = 'near_mids'
        include Apartment::Model
      end
      stub_const('NearMid', mid)
      mid.pin_tenant
      stub_const('NearChild', Class.new(mid) { self.table_name = 'near_children' })

      expect { adapter.send(:warn_unregistered_pinned_subclasses) }
        .to(output(/NearChild inherits a pin from NearMid/).to_stderr)
    end

    # The walk is advisory. It must never be able to fail a boot: it runs from
    # process_pinned_models, which Tenant.init calls in after_initialize.
    # An anonymous descendant has no model_name, so compute_table_name raises
    # ArgumentError — and Class.new(SomeBase) is a ubiquitous spec idiom.
    it 'does not raise on an anonymous descendant' do
      parent = Class.new(ActiveRecord::Base) do
        self.abstract_class = true
        include Apartment::Model
      end
      stub_const('AnonBase', parent)
      parent.pin_tenant
      Class.new(parent) { self.table_name = 'anon_things' }

      expect { adapter.send(:warn_unregistered_pinned_subclasses) }.not_to(raise_error)
    end

    it 'survives a descendant whose naming machinery raises' do
      parent = Class.new(ActiveRecord::Base) do
        self.table_name = 'boom_parents'
        include Apartment::Model
      end
      stub_const('BoomParent', parent)
      parent.pin_tenant
      child = Class.new(parent) { self.table_name = 'boom_children' }
      stub_const('BoomChild', child)
      allow(child).to(receive(:apartment_explicit_table_name?).and_raise(StandardError, 'boom'))

      expect { adapter.send(:warn_unregistered_pinned_subclasses) }.not_to(raise_error)
    end

    # Before descendants were resynced, a descendant that memoized its name
    # early kept a stale value that no longer matched compute_table_name, so
    # apartment_explicit_table_name? read true and this warned that the model
    # "declares its own table" — which it does not. A false diagnosis sends the
    # reader after the wrong fix.
    it 'does not warn about a descendant that merely memoized its name early' do
      parent = Class.new(ActiveRecord::Base) do
        self.abstract_class = true
        include Apartment::Model
      end
      stub_const('MemoWarnBase', parent)
      parent.pin_tenant
      child = Class.new(parent)
      stub_const('MemoWarnChild', child)
      child.table_name # early read
      # TestAdapter is abstract on purpose (another example asserts it raises);
      # supply the qualifier this one needs.
      allow(adapter).to(receive(:pinned_table_qualifier).and_return('public'))
      adapter.qualify_pinned_table_name(parent)

      expect { adapter.send(:warn_unregistered_pinned_subclasses) }.not_to(output.to_stderr)
    end

    it 'stays quiet once the subclass is registered itself' do
      parent = Class.new(ActiveRecord::Base) do
        self.table_name = 'reg_parents'
        include Apartment::Model
      end
      stub_const('RegParent', parent)
      parent.pin_tenant
      child = Class.new(parent) do
        self.table_name = 'reg_children'
        include Apartment::Model
      end
      stub_const('RegChild', child)
      child.pin_tenant

      expect { adapter.send(:warn_unregistered_pinned_subclasses) }.not_to(output.to_stderr)
    end
  end

  # A subclass sharing a pinned base's table needs nothing on EITHER path.
  # On the separate-pool path, establish_connection would hand it a different
  # pool from its parent — splitting two classes that share a physical table
  # across connections and breaking transactional integrity between them.
  describe '#process_pinned_model with a subclass sharing the base table' do
    it 'does not establish a separate connection for it' do
      allow(adapter).to(receive(:shared_pinned_connection?).and_return(false))
      parent = Class.new(ActiveRecord::Base) do
        self.table_name = 'sep_parents'
        include Apartment::Model
      end
      stub_const('SepParent', parent)
      parent.pin_tenant
      child = Class.new(parent) { include Apartment::Model }
      stub_const('SepChild', child)
      child.pin_tenant

      expect(child).not_to(receive(:establish_connection))

      adapter.process_pinned_model(child)
    end

    it 'still marks it processed so the batch does not retry' do
      allow(adapter).to(receive(:shared_pinned_connection?).and_return(false))
      parent = Class.new(ActiveRecord::Base) do
        self.table_name = 'sep2_parents'
        include Apartment::Model
      end
      stub_const('Sep2Parent', parent)
      parent.pin_tenant
      child = Class.new(parent) { include Apartment::Model }
      stub_const('Sep2Child', child)
      allow(child).to(receive(:establish_connection))

      adapter.process_pinned_model(child)

      expect(child.apartment_pinned_processed?).to(be(true))
    end
  end

  # The verification must not fire on the branch that deliberately mutates
  # nothing. A subclass sharing an already-pinned base's table is a no-op, and
  # if its base has not been qualified yet (registry order), asserting on it
  # would fail a boot for a model that is about to become correct.
  describe '#qualify_pinned_table_name verification scope' do
    it 'does not verify a subclass that shares the base table' do
      allow(adapter).to(receive(:pinned_table_qualifier).and_return('public'))
      parent = Class.new(ActiveRecord::Base) do
        self.table_name = 'order_parents'
        include Apartment::Model
      end
      stub_const('OrderParent', parent)
      parent.pin_tenant
      child = Class.new(parent) { include Apartment::Model }
      stub_const('OrderChild', child)
      child.pin_tenant

      # Parent deliberately NOT qualified yet — child is processed first.
      expect { adapter.qualify_pinned_table_name(child) }.not_to(raise_error)
      expect(child.table_name).to(eq('order_parents'))
    end
  end

  describe '#process_pinned_models' do
    context 'when shared_pinned_connection? is false (separate pool)' do
      it 'calls establish_connection with pinned_model_config' do
        model_class = Class.new(ActiveRecord::Base) do
          include Apartment::Model
        end
        stub_const('SeparatePinned', model_class)
        allow(model_class).to(receive(:table_name).and_return('separate_pinned'))
        allow(model_class).to(receive(:table_name=))

        SeparatePinned.pin_tenant

        # Schema strategy: pinned_model_config includes schema_search_path
        expected_config = {
          'adapter' => 'postgresql', 'host' => 'localhost',
          'schema_search_path' => '"public"'
        }
        expect(model_class).to(receive(:establish_connection)) do |arg|
          expect(arg).to(eq(expected_config))
        end

        adapter.process_pinned_models
      end

      it 'includes persistent schemas in pinned_model_config search_path' do
        model_class = Class.new(ActiveRecord::Base) do
          include Apartment::Model
        end
        stub_const('PersistentPinned', model_class)
        allow(model_class).to(receive(:table_name).and_return('persistent_pinned'))
        allow(model_class).to(receive(:table_name=))

        PersistentPinned.pin_tenant

        Apartment.configure do |c|
          c.tenant_strategy = :schema
          c.tenants_provider = -> { %w[t1 t2] }
          c.default_tenant = 'public'
          c.force_separate_pinned_pool = true
          c.configure_postgres { |pg| pg.persistent_schemas = %w[shared ext] }
        end

        expected_config = {
          'adapter' => 'postgresql', 'host' => 'localhost',
          'schema_search_path' => '"public","shared","ext"'
        }
        expect(model_class).to(receive(:establish_connection)) do |arg|
          expect(arg).to(eq(expected_config))
        end

        adapter.process_pinned_models
      end

      it 'uses plain base_config for database_name strategy' do
        model_class = Class.new(ActiveRecord::Base) do
          include Apartment::Model
        end
        stub_const('DbSeparatePinned', model_class)
        allow(model_class).to(receive(:table_name).and_return('db_separate_pinned'))

        DbSeparatePinned.pin_tenant

        reconfigure(tenant_strategy: :database_name)

        expected_config = { 'adapter' => 'postgresql', 'host' => 'localhost' }
        expect(model_class).to(receive(:establish_connection)) do |arg|
          expect(arg).to(eq(expected_config))
        end

        adapter.process_pinned_models
      end

      it 'does not call qualify_pinned_table_name' do
        model_class = Class.new(ActiveRecord::Base) do
          include Apartment::Model
        end
        stub_const('NoQualifyPinned', model_class)
        allow(model_class).to(receive(:table_name).and_return('no_qualify_pinned'))
        allow(model_class).to(receive(:establish_connection))

        NoQualifyPinned.pin_tenant

        expect(adapter).not_to(receive(:qualify_pinned_table_name))
        adapter.process_pinned_models
      end
    end

    context 'when shared_pinned_connection? is true (shared pool)' do
      before do
        allow(adapter).to(receive(:shared_pinned_connection?).and_return(true))
        allow(adapter).to(receive(:qualify_pinned_table_name))
      end

      it 'does not call establish_connection' do
        model_class = Class.new(ActiveRecord::Base) do
          include Apartment::Model
        end
        stub_const('SharedPinned', model_class)
        allow(model_class).to(receive(:table_name).and_return('shared_pinned'))

        SharedPinned.pin_tenant

        expect(model_class).not_to(receive(:establish_connection))
        adapter.process_pinned_models
      end

      it 'calls qualify_pinned_table_name' do
        model_class = Class.new(ActiveRecord::Base) do
          include Apartment::Model
        end
        stub_const('QualifyPinned', model_class)
        allow(model_class).to(receive(:table_name).and_return('qualify_pinned'))

        QualifyPinned.pin_tenant

        expect(adapter).to(receive(:qualify_pinned_table_name).with(model_class))
        adapter.process_pinned_models
      end
    end

    it 'skips models already processed (idempotent via apartment_pinned_processed?)' do
      model_class = Class.new(ActiveRecord::Base) do
        include Apartment::Model
      end
      stub_const('AlreadyPinned', model_class)
      allow(model_class).to(receive(:table_name).and_return('already_pinned'))
      allow(model_class).to(receive(:table_name=))

      AlreadyPinned.pin_tenant

      # First call processes the model
      allow(model_class).to(receive(:establish_connection))
      adapter.process_pinned_models

      # Second call skips — apartment_pinned_processed? returns true
      expect(model_class).not_to(receive(:establish_connection))
      adapter.process_pinned_models
    end

    it 'does nothing when no models are pinned' do
      expect { adapter.process_pinned_models }.not_to(raise_error)
    end

    it 'wraps errors with model-identifying context' do
      model_class = Class.new(ActiveRecord::Base) do
        include Apartment::Model
      end
      stub_const('BrokenPinned', model_class)

      BrokenPinned.pin_tenant

      allow(adapter).to(receive(:shared_pinned_connection?).and_return(true))
      allow(adapter).to(receive(:qualify_pinned_table_name).and_raise(StandardError, 'boom'))

      expect { adapter.process_pinned_models }.to(
        raise_error(Apartment::ConfigurationError, /Failed to process pinned model BrokenPinned.*boom/)
      )
    end

    it 'includes Apartment::Model and marks pinned for shim-registered models without the concern' do
      # Simulate excluded_models shim: register without including the concern
      klass = Class.new(ActiveRecord::Base)
      stub_const('ShimModel', klass)
      Apartment.register_pinned_model(klass)

      allow(klass).to(receive(:establish_connection))

      adapter.process_pinned_models

      expect(klass.respond_to?(:apartment_pinned?)).to(be(true))
      expect(klass.apartment_pinned?).to(be(true))
      expect(klass.apartment_pinned_processed?).to(be(true))
    end

    # Regression: clear_config keeps the pinned-model registry, so a
    # configure -> clear_config -> configure cycle must re-process pinned
    # models. Before the fix the registry was discarded, so the second
    # process_pinned_models found nothing and left the model unprocessed —
    # its table name no longer qualified to the default tenant.
    it 're-processes pinned models after a clear_config / configure cycle' do
      model_class = Class.new(ActiveRecord::Base) do
        include Apartment::Model
      end
      stub_const('ReprocessedAcrossClear', model_class)
      allow(model_class).to(receive(:establish_connection))

      ReprocessedAcrossClear.pin_tenant
      adapter.process_pinned_models
      expect(model_class.apartment_pinned_processed?).to(be(true))

      Apartment.clear_config
      expect(model_class.apartment_pinned_processed?).to(be(false))

      Apartment.configure do |c|
        c.tenant_strategy = :schema
        c.tenants_provider = -> { %w[t1 t2] }
        c.default_tenant = 'public'
      end
      adapter.process_pinned_models

      expect(model_class.apartment_pinned_processed?).to(be(true))
    end
  end

  describe '#process_excluded_models (deprecated)' do
    it 'emits a deprecation warning' do
      expect { adapter.process_excluded_models }
        .to(output(/DEPRECATION.*process_excluded_models/).to_stderr)
    end

    it 'delegates to process_pinned_models' do
      expect(adapter).to(receive(:process_pinned_models))
      adapter.process_excluded_models
    end
  end

  describe '#environmentify' do
    it 'prepends the environment when strategy is :prepend' do
      reconfigure(environmentify_strategy: :prepend)
      expect(adapter.environmentify('acme')).to(eq('test_acme'))
    end

    it 'appends the environment when strategy is :append' do
      reconfigure(environmentify_strategy: :append)
      expect(adapter.environmentify('acme')).to(eq('acme_test'))
    end

    it 'returns tenant as string when strategy is nil' do
      # Default config has environmentify_strategy = nil
      expect(adapter.environmentify('acme')).to(eq('acme'))
    end

    it 'converts symbols to string when strategy is nil' do
      expect(adapter.environmentify(:acme)).to(eq('acme'))
    end

    it 'calls the strategy when it is callable' do
      reconfigure(environmentify_strategy: ->(tenant) { "custom_#{tenant}" })
      expect(adapter.environmentify('acme')).to(eq('custom_acme'))
    end

    it 'raises ConfigurationError when Rails is not defined and strategy needs it' do
      reconfigure(environmentify_strategy: :prepend)
      # Simulate Rails being undefined by making rails_env raise
      allow(adapter).to(receive(:rails_env).and_raise(
                          Apartment::ConfigurationError,
                          'environmentify_strategy :prepend/:append requires Rails to be defined'
                        ))
      expect { adapter.environmentify('acme') }.to(raise_error(Apartment::ConfigurationError, /requires Rails/))
    end
  end

  describe '#default_tenant' do
    it 'delegates to Apartment.config.default_tenant' do
      expect(adapter.default_tenant).to(eq('public'))
    end
  end

  describe '#standard_privilege_statements' do
    let(:connection) { double('Connection') }

    # ConfigurationError, not NotImplementedError: the latter descends from
    # ScriptError, so an adopter's `rescue StandardError` around Tenant.create
    # would miss it and the process would die on a misconfiguration.
    it 'raises a rescuable error on a strategy with no standard policy', :aggregate_failures do
      reconfigure
      ctx = Apartment::Privileges::Context.new(
        tenant: 'acme', container_name: 'acme', connection: connection,
        db_role: nil, phase: :before_schema_load
      )

      raised = nil
      begin
        adapter.standard_privilege_statements(ctx, grant_to: 'app_user')
      rescue StandardError => e
        raised = e
      end

      expect(raised).to(be_a(Apartment::ConfigurationError))
      expect(raised.message).to(match(/does not support/))
    end

    it 'reports no database role by default' do
      reconfigure
      expect(adapter.current_db_role(connection)).to(be_nil)
    end
  end

  # PostgreSQL scopes an ALTER DEFAULT PRIVILEGES rule with no FOR ROLE to the role
  # that EXECUTES it, so a create-time rule covers the tables later migrations create
  # only if create and migrate run as the same role. Two further constraints force the
  # whole DDL sequence into one wrap rather than just the policy: the tenant container
  # is owned by whoever created it, and a policy handing the app role USAGE plus DML
  # but never CREATE leaves a schema import on the writing role unable to create
  # tables in a container it does not own.
  describe '#create under a configured ddl_role' do
    # Records the connected_to nesting depth so each step of create can be asserted to
    # run inside (1) or outside (0) the role wrap.
    def role_depth_tracker
      depth = 0
      observed_roles = []
      allow(ActiveRecord::Base).to(receive(:connected_to)) do |role:, &block|
        observed_roles << role
        depth += 1
        begin
          block.call
        ensure
          depth -= 1
        end
      end
      [-> { depth }, observed_roles]
    end

    before do
      allow(Apartment::Instrumentation).to(receive(:instrument))
      allow(Apartment).to(receive(:deregister_shard))
      allow(ActiveRecord::Base).to(receive(:connection).and_return(double('Connection')))
    end

    it 'runs create_tenant, both policy phases, and the schema import inside the DDL role' do
      current_depth, observed_roles = role_depth_tracker
      depths = {}
      policy = ->(ctx) { depths[ctx.phase] = current_depth.call }
      reconfigure(ddl_role: :db_manager, tenant_privilege_policy: policy, schema_load_strategy: :schema_rb)
      allow(adapter).to(receive(:current_db_role).and_return('db_manager'))
      allow(adapter).to(receive(:create_tenant) { depths[:create_tenant] = current_depth.call })
      allow(adapter).to(receive(:import_schema) { depths[:import_schema] = current_depth.call })

      adapter.create('acme')

      expect(depths).to(eq(create_tenant: 1, before_schema_load: 1, import_schema: 1, after_schema_load: 1))
      expect(observed_roles).to(eq([:db_manager]))
    end

    it 'runs seeding outside the migration role, because seeding writes data' do
      reconfigure(ddl_role: :db_manager, seed_after_create: true)
      current_depth, = role_depth_tracker
      seed_depth = nil
      allow(adapter).to(receive(:seed) { seed_depth = current_depth.call })

      adapter.create('acme')

      expect(seed_depth).to(eq(0))
    end

    it 'discards the DDL-role pool the schema import opened for the new tenant' do
      reconfigure(ddl_role: :db_manager, schema_load_strategy: :schema_rb)
      role_depth_tracker
      allow(adapter).to(receive(:import_schema))

      adapter.create('acme')

      expect(Apartment).to(have_received(:deregister_shard).with('acme:db_manager'))
    end

    it 'releases the connection the schema import leased before discarding the pool' do
      reconfigure(ddl_role: :db_manager, schema_load_strategy: :schema_rb)
      role_depth_tracker
      allow(adapter).to(receive(:import_schema))
      pool = instance_double(ActiveRecord::ConnectionAdapters::ConnectionPool, connections: [])
      allow(pool).to(receive(:release_connection))
      pool_manager = instance_double(Apartment::PoolManager, peek: pool)
      allow(Apartment).to(receive(:pool_manager).and_return(pool_manager))

      adapter.create('acme')

      # Without the release, the in-use check would see this thread's own lease and
      # skip the discard on every create.
      expect(pool).to(have_received(:release_connection))
      expect(Apartment).to(have_received(:deregister_shard).with('acme:db_manager'))
    end

    it 'leaves a pool another operation is using registered' do
      reconfigure(ddl_role: :db_manager, schema_load_strategy: :schema_rb)
      role_depth_tracker
      allow(adapter).to(receive(:import_schema))
      busy = double('Connection', in_use?: true, open_transactions: 0)
      pool = instance_double(ActiveRecord::ConnectionAdapters::ConnectionPool, connections: [busy])
      allow(pool).to(receive(:release_connection))
      pool_manager = instance_double(Apartment::PoolManager, peek: pool)
      allow(Apartment).to(receive(:pool_manager).and_return(pool_manager))

      adapter.create('acme')

      # A concurrent migration of this same tenant leases the same
      # "<tenant>:<ddl_role>" pool. Disconnecting it under that migration is
      # worse than leaving a pool for the reaper to collect.
      expect(Apartment).not_to(have_received(:deregister_shard))
    end

    it 'discards that pool even when the schema import raises' do
      reconfigure(ddl_role: :db_manager, schema_load_strategy: :schema_rb)
      role_depth_tracker
      allow(adapter).to(receive(:import_schema).and_raise(Apartment::SchemaLoadError, 'boom'))

      expect { adapter.create('acme') }.to(raise_error(Apartment::SchemaLoadError))

      expect(Apartment).to(have_received(:deregister_shard).with('acme:db_manager'))
    end
  end

  describe '#create and the privilege policy' do
    let(:connection) { double('Connection') }

    before do
      allow(Apartment::Instrumentation).to(receive(:instrument))
      allow(ActiveRecord::Base).to(receive(:connection).and_return(connection))
      allow(adapter).to(receive(:current_db_role).and_return('db_manager'))
    end

    it 'invokes the policy once per phase, in order' do
      phases = []
      reconfigure(tenant_privilege_policy: ->(ctx) { phases << ctx.phase })

      adapter.create('acme')

      expect(phases).to(eq(%i[before_schema_load after_schema_load]))
    end

    it 'invokes both phases even when no schema is loaded' do
      phases = []
      reconfigure(schema_load_strategy: nil, tenant_privilege_policy: ->(ctx) { phases << ctx.phase })

      adapter.create('acme')

      # :after_schema_load means "after the import step", including when that step
      # did nothing. A policy behaves the same either way.
      expect(phases.size).to(eq(2))
    end

    it 'brackets the schema import between the phases' do
      order = []
      allow(adapter).to(receive(:import_schema) { order << :import })
      reconfigure(schema_load_strategy: :schema_rb,
                  tenant_privilege_policy: ->(ctx) { order << ctx.phase })

      adapter.create('acme')

      expect(order).to(eq(%i[before_schema_load import after_schema_load]))
    end

    it 'gives the policy the physical container name, not the logical tenant' do
      names = []
      reconfigure(environmentify_strategy: :append,
                  tenant_privilege_policy: ->(ctx) { names << [ctx.tenant, ctx.container_name] })

      adapter.create('acme')

      # A policy interpolating the logical name would target the wrong object
      # under any environmentify_strategy.
      expect(names.first).to(eq(['acme', adapter.send(:physical_tenant_name, 'acme')]))
    end

    # One round trip per create, and the SAME role reported to both phases. The
    # value matters as much as the count: db_role is the field that lets a policy
    # write ALTER DEFAULT PRIVILEGES FOR ROLE and be correct by statement rather
    # than by position, so replacing it with nil must not stay green.
    it 'resolves the database role once and reports it to both phases', :aggregate_failures do
      roles = []
      reconfigure(tenant_privilege_policy: ->(ctx) { roles << ctx.db_role })

      adapter.create('acme')

      expect(adapter).to(have_received(:current_db_role).once)
      expect(roles).to(eq(%w[db_manager db_manager]))
    end

    # Resolution is skipped entirely without a policy, so an adopter who manages
    # privileges elsewhere pays no round trip.
    it 'does not resolve the database role when no policy is configured' do
      reconfigure

      adapter.create('acme')

      expect(adapter).not_to(have_received(:current_db_role))
    end

    it 'aborts the create when the policy raises, without seeding', :aggregate_failures do
      reconfigure(seed_after_create: true,
                  tenant_privilege_policy: ->(_ctx) { raise(ArgumentError, 'boom') })
      allow(adapter).to(receive(:seed))

      expect { adapter.create('acme') }.to(raise_error(ArgumentError, 'boom'))

      expect(adapter).not_to(have_received(:seed))
      expect(Apartment::Instrumentation).not_to(have_received(:instrument).with(:create, anything))
    end

    it 'creates the tenant without a policy configured' do
      reconfigure

      expect { adapter.create('acme') }.not_to(raise_error)
      expect(adapter.created_tenants).to(include('acme'))
    end
  end

  describe '#create without a ddl_role' do
    it 'issues the DDL on the current role and discards no pool' do
      reconfigure(schema_load_strategy: :schema_rb)
      allow(Apartment::Instrumentation).to(receive(:instrument))
      allow(adapter).to(receive(:import_schema))
      expect(ActiveRecord::Base).not_to(receive(:connected_to))
      expect(Apartment).not_to(receive(:deregister_shard))

      adapter.create('acme')
    end
  end

  describe '#create and the pending-migration check' do
    before { allow(Apartment::Instrumentation).to(receive(:instrument)) }

    after { Apartment::Current.migrating = nil }

    it 'suppresses the check while the tenant is being built' do
      reconfigure
      observed = nil
      allow(adapter).to(receive(:create_tenant) { observed = Apartment::Current.migrating })

      adapter.create('acme')

      # import_schema and seed switch into a container that has run no migration, so
      # the check would otherwise fire against the thing being created.
      expect(observed).to(be(true))
    end

    it 'restores the flag afterwards' do
      reconfigure

      adapter.create('acme')

      expect(Apartment::Current.migrating).to(be_falsey)
    end

    it 'restores the flag when the create raises' do
      reconfigure
      allow(adapter).to(receive(:create_tenant).and_raise(ArgumentError, 'boom'))

      expect { adapter.create('acme') }.to(raise_error(ArgumentError))

      expect(Apartment::Current.migrating).to(be_falsey)
    end

    it 'covers the :create callbacks, so one touching the new tenant is protected' do
      reconfigure
      observed = nil
      TestAdapter.set_callback(:create, :after) { observed = Apartment::Current.migrating }

      begin
        adapter.create('acme')
      ensure
        TestAdapter.reset_callbacks(:create)
      end

      # Provisioning rows in the tenant just created is what a :create callback is for,
      # and with schema_load_strategy nil that tenant has no schema_migrations, so a
      # window narrower than the callback chain would leave the callback raising.
      # The accepted cost is that a callback switching to an unrelated cold tenant also
      # skips its check; see suppressing_pending_migration_check.
      expect(observed).to(be(true))
    end

    it 'leaves an enclosing migration still suppressed' do
      reconfigure
      Apartment::Current.migrating = true

      adapter.create('acme')

      # A create nested inside a migration — an adopter :create callback, or a
      # create-then-migrate helper — must not disarm the migration on its way out.
      expect(Apartment::Current.migrating).to(be(true))
    end
  end

  describe '#create with schema loading' do
    it 'calls import_schema when schema_load_strategy is set' do
      reconfigure(schema_load_strategy: :schema_rb)
      allow(Apartment::Instrumentation).to(receive(:instrument))
      expect(adapter).to(receive(:import_schema).with('acme'))
      adapter.create('acme')
    end

    it 'does not call import_schema when strategy is nil' do
      # Default in tests is nil
      allow(Apartment::Instrumentation).to(receive(:instrument))
      expect(adapter).not_to(receive(:import_schema))
      adapter.create('acme')
    end

    it 'calls seed after schema when seed_after_create is true' do
      reconfigure(schema_load_strategy: :schema_rb, seed_after_create: true, seed_data_file: '/tmp/seeds.rb')
      allow(Apartment::Instrumentation).to(receive(:instrument))
      call_order = []
      allow(adapter).to(receive(:import_schema) { call_order << :schema })
      allow(File).to(receive(:exist?).and_return(true))
      allow(adapter).to(receive(:load) { call_order << :seed })
      adapter.create('acme')
      expect(call_order).to(eq(%i[schema seed]))
    end
  end

  describe '#resolve_schema_file (private)' do
    it 'returns custom schema_file when configured' do
      reconfigure(schema_file: '/custom/schema.rb')
      expect(adapter.send(:resolve_schema_file)).to(eq('/custom/schema.rb'))
    end

    it 'returns db/schema.rb path when Rails is defined' do
      result = adapter.send(:resolve_schema_file)
      expect(result).to(include('schema.rb'))
    end
  end

  describe '#import_schema (private)' do
    it 'calls load with resolved schema file for :schema_rb' do
      reconfigure(schema_load_strategy: :schema_rb, schema_file: '/tmp/test_schema.rb')
      expect(adapter).to(receive(:load).with('/tmp/test_schema.rb'))
      adapter.send(:import_schema, 'acme')
    end

    it 'wraps errors in SchemaLoadError' do
      reconfigure(schema_load_strategy: :schema_rb, schema_file: '/tmp/bad.rb')
      allow(adapter).to(receive(:load).and_raise(RuntimeError, 'syntax error'))
      expect { adapter.send(:import_schema, 'acme') }
        .to(raise_error(Apartment::SchemaLoadError, /syntax error/))
    end
  end

  describe 'protected abstract methods' do
    it 'create_tenant raises NotImplementedError on the abstract class' do
      abstract = described_class.new(connection_config)
      expect { abstract.send(:create_tenant, 't1') }.to(raise_error(NotImplementedError))
    end

    it 'drop_tenant raises NotImplementedError on the abstract class' do
      abstract = described_class.new(connection_config)
      expect { abstract.send(:drop_tenant, 't1') }.to(raise_error(NotImplementedError))
    end
  end
end
