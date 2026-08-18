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

  describe '#grant_tenant_privileges (private)' do
    let(:connection) { double('Connection') }

    before do
      allow(ActiveRecord::Base).to(receive(:connection).and_return(connection))
      allow(Apartment::Instrumentation).to(receive(:instrument))
    end

    context 'when app_role is a string' do
      before { reconfigure(app_role: 'app_user') }

      it 'calls grant_privileges with tenant, connection, and role_name' do
        expect(adapter).to(receive(:grant_privileges).with('acme', connection, 'app_user'))
        adapter.create('acme')
      end
    end

    context 'when app_role is callable' do
      it 'invokes the callable with (tenant, connection)' do
        called_with = nil
        reconfigure(app_role: ->(tenant, conn) { called_with = [tenant, conn] })

        adapter.create('acme')

        expect(called_with).to(eq(['acme', connection]))
      end
    end

    context 'when app_role is nil' do
      it 'does not call grant_privileges and does not raise' do
        # Default config has app_role = nil
        expect(adapter).not_to(receive(:grant_privileges))
        expect { adapter.create('acme') }.not_to(raise_error)
      end
    end

    context 'ordering: grants run after create_tenant, before import_schema' do
      it 'calls create_tenant then grant_tenant_privileges then import_schema' do
        reconfigure(app_role: 'app_user', schema_load_strategy: :schema_rb)
        call_order = []

        allow(adapter).to(receive(:create_tenant).with('acme') { call_order << :create_tenant })
        allow(adapter).to(receive(:grant_privileges) { call_order << :grant_privileges })
        allow(adapter).to(receive(:import_schema).with('acme') { call_order << :import_schema })

        adapter.create('acme')

        expect(call_order).to(eq(%i[create_tenant grant_privileges import_schema]))
      end
    end
  end

  # PostgreSQL scopes the ALTER DEFAULT PRIVILEGES rule that grant_privileges installs
  # to the role that EXECUTES it, so create-time grants cover the tables later
  # migrations create only if create and migrate run as the same role. Two further
  # constraints force the whole DDL sequence into one wrap rather than just the grants:
  # the tenant container is owned by whoever created it, and grant_privileges hands the
  # app role USAGE plus DML but never CREATE, so a schema import left on the writing
  # role could not create tables in a container it does not own.
  describe '#create under a configured migration_role' do
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

    it 'runs create_tenant, the grants, and the schema import inside the migration role' do
      reconfigure(migration_role: :db_manager, app_role: 'app_user', schema_load_strategy: :schema_rb)
      current_depth, observed_roles = role_depth_tracker
      depths = {}
      allow(adapter).to(receive(:create_tenant) { depths[:create_tenant] = current_depth.call })
      allow(adapter).to(receive(:grant_privileges) { depths[:grant_privileges] = current_depth.call })
      allow(adapter).to(receive(:import_schema) { depths[:import_schema] = current_depth.call })

      adapter.create('acme')

      expect(depths).to(eq(create_tenant: 1, grant_privileges: 1, import_schema: 1))
      expect(observed_roles).to(eq([:db_manager]))
    end

    it 'runs seeding outside the migration role, because seeding writes data' do
      reconfigure(migration_role: :db_manager, seed_after_create: true)
      current_depth, = role_depth_tracker
      seed_depth = nil
      allow(adapter).to(receive(:seed) { seed_depth = current_depth.call })

      adapter.create('acme')

      expect(seed_depth).to(eq(0))
    end

    it 'discards the migration-role pool the schema import opened for the new tenant' do
      reconfigure(migration_role: :db_manager, schema_load_strategy: :schema_rb)
      role_depth_tracker
      allow(adapter).to(receive(:import_schema))

      adapter.create('acme')

      expect(Apartment).to(have_received(:deregister_shard).with('acme:db_manager'))
    end

    it 'discards that pool even when the schema import raises' do
      reconfigure(migration_role: :db_manager, schema_load_strategy: :schema_rb)
      role_depth_tracker
      allow(adapter).to(receive(:import_schema).and_raise(Apartment::SchemaLoadError, 'boom'))

      expect { adapter.create('acme') }.to(raise_error(Apartment::SchemaLoadError))

      expect(Apartment).to(have_received(:deregister_shard).with('acme:db_manager'))
    end
  end

  describe '#create without a migration_role' do
    it 'issues the DDL on the current role and discards no pool' do
      reconfigure(schema_load_strategy: :schema_rb)
      allow(Apartment::Instrumentation).to(receive(:instrument))
      allow(adapter).to(receive(:import_schema))
      expect(ActiveRecord::Base).not_to(receive(:connected_to))
      expect(Apartment).not_to(receive(:deregister_shard))

      adapter.create('acme')
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
