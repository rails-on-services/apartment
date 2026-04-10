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

# Minimal Rails stub for environmentify tests.
unless defined?(Rails)
  module Rails
    def self.env
      'test'
    end

    def self.root
      Pathname.new('/rails/app')
    end
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

RSpec.describe(Apartment::Adapters::AbstractAdapter) do
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

  describe '#qualify_pinned_table_name' do
    it 'raises NotImplementedError on the abstract class' do
      klass = Class.new(ActiveRecord::Base)
      expect { adapter.qualify_pinned_table_name(klass) }.to(
        raise_error(NotImplementedError, /qualify_pinned_table_name must be implemented/)
      )
    end
  end

  describe '#explicit_table_name? (private)' do
    it 'returns false when @table_name is not set' do
      klass = Class.new(ActiveRecord::Base)
      stub_const('NoTableName', klass)
      expect(adapter.send(:explicit_table_name?, klass)).to(be(false))
    end

    it 'returns false when cached equals computed (convention naming)' do
      klass = Class.new(ActiveRecord::Base)
      stub_const('ConventionModel', klass)
      allow(klass).to(receive(:compute_table_name).and_return('convention_models'))
      klass.instance_variable_set(:@table_name, 'convention_models')
      expect(adapter.send(:explicit_table_name?, klass)).to(be(false))
    end

    it 'returns true when cached differs from computed (explicit assignment)' do
      klass = Class.new(ActiveRecord::Base)
      stub_const('ExplicitModel', klass)
      allow(klass).to(receive(:compute_table_name).and_return('explicit_models'))
      klass.instance_variable_set(:@table_name, 'custom_table')
      expect(adapter.send(:explicit_table_name?, klass)).to(be(true))
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
