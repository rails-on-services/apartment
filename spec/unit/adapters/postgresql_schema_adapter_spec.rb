# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../lib/apartment/adapters/postgresql_schema_adapter'

# Minimal ActiveRecord stubs for SQL execution tests.
unless defined?(ActiveRecord::Base)
  module ActiveRecord
    class Base
      def self.connection
        raise('stub: override with allow in tests')
      end
    end
  end
end

RSpec.describe(Apartment::Adapters::PostgresqlSchemaAdapter) do
  let(:connection_config) { { adapter: 'postgresql', host: 'localhost', database: 'myapp' } }
  let(:adapter) { described_class.new(connection_config) }

  before do
    Apartment.configure do |c|
      c.tenant_strategy = :schema
      c.tenants_provider = -> { %w[t1 t2] }
      c.default_tenant = 'public'
      c.schema_load_strategy = nil
    end
  end

  # Helper: reconfigure Apartment with overrides (Config is frozen after configure,
  # so we must reconfigure rather than stub individual accessors).
  def reconfigure(**overrides, &block)
    Apartment.configure do |c|
      c.tenant_strategy = :schema
      c.tenants_provider = -> { %w[t1 t2] }
      c.default_tenant = 'public'
      c.schema_load_strategy = nil
      overrides.each { |key, val| c.send(:"#{key}=", val) }
      block&.call(c)
    end
  end

  describe 'inheritance' do
    it 'is a subclass of AbstractAdapter' do
      expect(described_class).to(be < Apartment::Adapters::AbstractAdapter)
    end
  end

  describe '#shared_pinned_connection?' do
    it 'returns true (schemas share a catalog)' do
      expect(adapter.shared_pinned_connection?).to(be(true))
    end

    it 'returns false when force_separate_pinned_pool is true' do
      reconfigure { |c| c.force_separate_pinned_pool = true }
      expect(adapter.shared_pinned_connection?).to(be(false))
    end
  end

  describe '#qualify_pinned_table_name' do
    it 'qualifies convention-named model via table_name_prefix + reset_table_name' do
      klass = Class.new(ActiveRecord::Base) { include Apartment::Model }
      stub_const('DelayedJob', klass)

      expect(klass).to(receive(:table_name_prefix=).with('public.'))
      expect(klass).to(receive(:reset_table_name))

      adapter.qualify_pinned_table_name(klass)
    end

    it 'qualifies explicit table_name via direct assignment' do
      klass = Class.new(ActiveRecord::Base) { include Apartment::Model }
      stub_const('ExplicitPinned', klass)
      klass.instance_variable_set(:@table_name, 'custom_jobs')
      allow(klass).to(receive_messages(compute_table_name: 'explicit_pinneds', table_name: 'custom_jobs'))

      expect(klass).to(receive(:table_name=).with('public.custom_jobs'))
      expect(klass).not_to(receive(:table_name_prefix=))

      adapter.qualify_pinned_table_name(klass)
    end

    it 'strips existing schema prefix before re-qualifying' do
      klass = Class.new(ActiveRecord::Base) { include Apartment::Model }
      stub_const('RequalifyPinned', klass)
      klass.instance_variable_set(:@table_name, 'old_schema.jobs')
      allow(klass).to(receive_messages(compute_table_name: 'requalify_pinneds', table_name: 'old_schema.jobs'))

      expect(klass).to(receive(:table_name=).with('public.jobs'))

      adapter.qualify_pinned_table_name(klass)
    end

    it 'marks model as processed with original prefix on convention path' do
      klass = Class.new(ActiveRecord::Base) { include Apartment::Model }
      stub_const('PrefixPinned', klass)
      allow(klass).to(receive(:table_name_prefix).and_return('myapp_'))
      allow(klass).to(receive(:table_name_prefix=))
      allow(klass).to(receive(:reset_table_name))

      adapter.qualify_pinned_table_name(klass)

      expect(klass.apartment_pinned_processed?).to(be(true))
    end

    it 'marks model as processed after mutation on explicit path' do
      klass = Class.new(ActiveRecord::Base) { include Apartment::Model }
      stub_const('IvarOrderPinned', klass)
      klass.instance_variable_set(:@table_name, 'custom_jobs')
      allow(klass).to(receive_messages(compute_table_name: 'ivar_order_pinneds', table_name: 'custom_jobs'))
      allow(klass).to(receive(:table_name=))

      adapter.qualify_pinned_table_name(klass)

      expect(klass.apartment_pinned_processed?).to(be(true))
    end
  end

  describe '#resolve_connection_config' do
    it 'returns config with schema_search_path set to tenant name' do
      result = adapter.resolve_connection_config('acme')

      expect(result['schema_search_path']).to(eq('"acme"'))
    end

    it 'quotes schema names to handle special characters like hyphens' do
      result = adapter.resolve_connection_config('test-tenant')

      expect(result['schema_search_path']).to(eq('"test-tenant"'))
    end

    it 'stringifies all config keys' do
      result = adapter.resolve_connection_config('acme')

      expect(result.keys).to(all(be_a(String)))
      expect(result['adapter']).to(eq('postgresql'))
      expect(result['host']).to(eq('localhost'))
      expect(result['database']).to(eq('myapp'))
    end

    it 'includes persistent_schemas when postgres_config is set' do
      reconfigure do |c|
        c.configure_postgres do |pg|
          pg.persistent_schemas = %w[shared extensions]
        end
      end

      result = adapter.resolve_connection_config('acme')

      expect(result['schema_search_path']).to(eq('"acme","shared","extensions"'))
    end

    it 'works when no postgres_config is set (nil persistent schemas)' do
      # Default config has postgres_config = nil
      expect(Apartment.config.postgres_config).to(be_nil)

      result = adapter.resolve_connection_config('acme')

      expect(result['schema_search_path']).to(eq('"acme"'))
    end

    it 'works when postgres_config exists but persistent_schemas is empty' do
      reconfigure do |c|
        c.configure_postgres do |pg|
          pg.persistent_schemas = []
        end
      end

      result = adapter.resolve_connection_config('acme')

      expect(result['schema_search_path']).to(eq('"acme"'))
    end

    it 'preserves all original connection config keys' do
      config = { adapter: 'postgresql', host: 'db.example.com', database: 'app', port: 5432, pool: 10 }
      local_adapter = described_class.new(config)

      result = local_adapter.resolve_connection_config('tenant1')

      expect(result['port']).to(eq(5432))
      expect(result['pool']).to(eq(10))
    end

    it 'does not mutate the original connection_config' do
      adapter.resolve_connection_config('acme')

      expect(adapter.connection_config).to(eq(connection_config))
      expect(adapter.connection_config).not_to(have_key('schema_search_path'))
      expect(adapter.connection_config).not_to(have_key(:schema_search_path))
    end
  end

  describe '#create (via create_tenant)' do
    let(:connection) { double('Connection') }

    before do
      allow(ActiveRecord::Base).to(receive(:connection).and_return(connection))
      allow(Apartment::Instrumentation).to(receive(:instrument))
    end

    it 'executes CREATE SCHEMA with quoted tenant name' do
      allow(connection).to(receive(:quote_table_name).with('acme').and_return('"acme"'))
      expect(connection).to(receive(:execute).with('CREATE SCHEMA IF NOT EXISTS "acme"'))

      adapter.create('acme')
    end

    it 'uses raw tenant name, not environmentified (schemas are named directly)' do
      reconfigure(environmentify_strategy: :prepend)
      # Schema names are NOT environmentified — unlike database-per-tenant adapters.
      # The schema lives inside an already-environment-specific database.
      allow(connection).to(receive(:quote_table_name).with('acme').and_return('"acme"'))
      expect(connection).to(receive(:execute).with('CREATE SCHEMA IF NOT EXISTS "acme"'))

      adapter.create('acme')
    end

    it 'quotes tenant names that need escaping' do
      allow(connection).to(receive(:quote_table_name).with('my-tenant').and_return('"my-tenant"'))
      expect(connection).to(receive(:execute).with('CREATE SCHEMA IF NOT EXISTS "my-tenant"'))

      adapter.create('my-tenant')
    end
  end

  describe '#drop (via drop_tenant)' do
    let(:connection) { double('Connection') }
    let(:pool_manager) { Apartment.pool_manager }

    before do
      allow(ActiveRecord::Base).to(receive(:connection).and_return(connection))
      allow(Apartment::Instrumentation).to(receive(:instrument))
      allow(pool_manager).to(receive(:remove_tenant).and_return([]))
      allow(Apartment).to(receive(:deregister_shard))
    end

    it 'executes DROP SCHEMA IF EXISTS CASCADE with quoted tenant name' do
      allow(connection).to(receive(:quote_table_name).with('acme').and_return('"acme"'))
      expect(connection).to(receive(:execute).with('DROP SCHEMA IF EXISTS "acme" CASCADE'))

      adapter.drop('acme')
    end

    it 'quotes tenant names that need escaping' do
      allow(connection).to(receive(:quote_table_name).with('my-tenant').and_return('"my-tenant"'))
      expect(connection).to(receive(:execute).with('DROP SCHEMA IF EXISTS "my-tenant" CASCADE'))

      adapter.drop('my-tenant')
    end

    it 'uses raw tenant name, not environmentified' do
      reconfigure(environmentify_strategy: :prepend)
      allow(connection).to(receive(:quote_table_name).with('acme').and_return('"acme"'))
      expect(connection).to(receive(:execute).with('DROP SCHEMA IF EXISTS "acme" CASCADE'))

      adapter.drop('acme')
    end
  end

  describe '#grant_privileges (private)' do
    let(:connection) { double('Connection') }

    before do
      allow(ActiveRecord::Base).to(receive(:connection).and_return(connection))
      allow(Apartment::Instrumentation).to(receive(:instrument))
      allow(connection).to(receive(:quote_table_name).with('acme').and_return('"acme"'))
      allow(connection).to(receive(:quote_table_name).with('app_user').and_return('"app_user"'))
      # Allow CREATE SCHEMA call from create_tenant
      allow(connection).to(receive(:execute).with('CREATE SCHEMA IF NOT EXISTS "acme"'))
    end

    it 'executes exactly 6 SQL statements when app_role is set' do
      reconfigure(app_role: 'app_user')
      expect(connection).to(receive(:execute).exactly(6).times)

      adapter.send(:grant_privileges, 'acme', connection, 'app_user')
    end

    it 'includes GRANT USAGE ON SCHEMA' do
      expect(connection).to(receive(:execute).with('GRANT USAGE ON SCHEMA "acme" TO "app_user"'))
      allow(connection).to(receive(:execute))

      adapter.send(:grant_privileges, 'acme', connection, 'app_user')
    end

    it 'includes ALTER DEFAULT PRIVILEGES for tables' do
      expect(connection).to(receive(:execute)
        .with('ALTER DEFAULT PRIVILEGES IN SCHEMA "acme" ' \
              'GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO "app_user"'))
      allow(connection).to(receive(:execute))

      adapter.send(:grant_privileges, 'acme', connection, 'app_user')
    end

    it 'includes ALTER DEFAULT PRIVILEGES for sequences' do
      expect(connection).to(receive(:execute)
        .with('ALTER DEFAULT PRIVILEGES IN SCHEMA "acme" ' \
              'GRANT USAGE, SELECT ON SEQUENCES TO "app_user"'))
      allow(connection).to(receive(:execute))

      adapter.send(:grant_privileges, 'acme', connection, 'app_user')
    end

    it 'includes ALTER DEFAULT PRIVILEGES for functions' do
      expect(connection).to(receive(:execute)
        .with('ALTER DEFAULT PRIVILEGES IN SCHEMA "acme" ' \
              'GRANT EXECUTE ON FUNCTIONS TO "app_user"'))
      allow(connection).to(receive(:execute))

      adapter.send(:grant_privileges, 'acme', connection, 'app_user')
    end

    it 'includes GRANT on ALL TABLES' do
      expect(connection).to(receive(:execute)
        .with('GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA "acme" TO "app_user"'))
      allow(connection).to(receive(:execute))

      adapter.send(:grant_privileges, 'acme', connection, 'app_user')
    end

    it 'includes GRANT USAGE, SELECT on ALL SEQUENCES' do
      expect(connection).to(receive(:execute)
        .with('GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA "acme" TO "app_user"'))
      allow(connection).to(receive(:execute))

      adapter.send(:grant_privileges, 'acme', connection, 'app_user')
    end
  end

  describe '#validated_connection_config with base_config_override' do
    it 'uses the override host and username instead of adapter base_config' do
      override_config = {
        'adapter' => 'postgresql',
        'host' => 'replica.example.com',
        'username' => 'readonly',
        'database' => 'myapp',
      }

      result = adapter.validated_connection_config('acme', base_config_override: override_config)

      expect(result['host']).to(eq('replica.example.com'))
      expect(result['username']).to(eq('readonly'))
      expect(result['schema_search_path']).to(eq('"acme"'))
    end

    it 'falls back to adapter base_config when override is nil' do
      result = adapter.validated_connection_config('acme', base_config_override: nil)

      expect(result['host']).to(eq('localhost'))
      expect(result['schema_search_path']).to(eq('"acme"'))
    end
  end
end
