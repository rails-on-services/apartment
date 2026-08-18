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

  # Qualification itself lives in AbstractAdapter; this adapter only supplies
  # the qualifier. End-to-end table_name behaviour is covered for real (no
  # mutator mocks) in spec/unit/adapters/pinned_table_qualification_spec.rb.
  describe '#pinned_table_qualifier' do
    it 'is the default tenant schema' do
      expect(adapter.pinned_table_qualifier).to(eq('public'))
    end

    it 'follows a reconfigured default_tenant' do
      reconfigure(default_tenant: 'shared')

      expect(adapter.pinned_table_qualifier).to(eq('shared'))
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

    it 'validates the raw (physical) schema name on create, even with environmentify_strategy' do
      # Regression: create previously validated environmentify(tenant), so a raw
      # "pg_"-prefixed name slipped through under :prepend (the env prefix masked
      # the reserved prefix) while CREATE SCHEMA still used the raw name. create
      # now validates the physical (raw) name, matching the pool-resolution path.
      reconfigure(environmentify_strategy: :prepend)
      expect(connection).not_to(receive(:execute))
      expect { adapter.create('pg_evil') }
        .to(raise_error(Apartment::ConfigurationError, /pg_/))
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

  describe '#standard_privilege_statements' do
    let(:connection) { double('Connection') }

    def context(phase)
      Apartment::Privileges::Context.new(
        tenant: 'acme', container_name: 'acme', connection: connection,
        db_role: 'db_manager', phase: phase
      )
    end

    before do
      allow(connection).to(receive(:quote_table_name)) { |name| %("#{name}") }
      reconfigure
    end

    # The default-privileges rules go BEFORE the import so they cover imported
    # tables and everything migrations add later. Getting this backwards is the
    # regression the two-phase design exists to prevent — see the spec.
    it 'issues the default-privileges rules before the schema load', :aggregate_failures do
      statements = adapter.standard_privilege_statements(
        context(:before_schema_load), grant_to: 'app_user', include_functions: true
      )

      expect(statements).to(include(a_string_matching(/GRANT USAGE ON SCHEMA "acme" TO "app_user"/)))
      expect(statements.grep(/ALTER DEFAULT PRIVILEGES/).size).to(eq(3))
      expect(statements).to(include(a_string_matching(/ALTER DEFAULT PRIVILEGES FOR ROLE "db_manager"/)))
      expect(statements).to(include(a_string_matching(/ON FUNCTIONS TO "app_user"/)))
    end

    it 'omits the functions rule when include_functions is false' do
      statements = adapter.standard_privilege_statements(
        context(:before_schema_load), grant_to: 'app_user', include_functions: false
      )

      expect(statements.grep(/ON FUNCTIONS/)).to(be_empty)
    end

    # Objects that exist by now: the import created them, and the default-privileges
    # rule does not retroactively cover objects created before it was recorded.
    it 'grants on existing objects after the schema load', :aggregate_failures do
      statements = adapter.standard_privilege_statements(
        context(:after_schema_load), grant_to: 'app_user', include_functions: true
      )

      expect(statements).to(include(a_string_matching(/ON ALL TABLES IN SCHEMA "acme"/)))
      expect(statements).to(include(a_string_matching(/ON ALL SEQUENCES IN SCHEMA "acme"/)))
      expect(statements.grep(/ALTER DEFAULT PRIVILEGES/)).to(be_empty)
    end

    it 'grants to every role it is given' do
      statements = adapter.standard_privilege_statements(
        context(:after_schema_load), grant_to: %w[app_web app_worker], include_functions: true
      )

      expect(statements.first).to(match(/TO "app_web", "app_worker"/))
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

  describe '#physical_tenant_name' do
    # Schema-per-tenant names schemas directly, so pool-resolution validates and
    # uses the RAW tenant even when environmentify_strategy is set — unlike the
    # database-per-tenant adapters, which validate the environmentified name.
    it 'validates the raw tenant name, ignoring environmentify_strategy' do
      reconfigure(environmentify_strategy: ->(t) { "#{t}\x00" })
      expect { adapter.validated_connection_config('acme') }.not_to(raise_error)
    end

    it 'resolves the search_path from the raw tenant name' do
      reconfigure(environmentify_strategy: ->(t) { "#{t}_ignored" })
      config = adapter.validated_connection_config('acme')
      expect(config['schema_search_path']).to(eq('"acme"'))
    end
  end
end
