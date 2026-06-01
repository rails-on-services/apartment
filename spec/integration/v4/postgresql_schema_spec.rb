# frozen_string_literal: true

require 'spec_helper'
require 'rack'
require 'rack/mock'
require_relative 'support'

RSpec.describe('v4 PostgreSQL schema integration', :integration,
               skip: (V4_INTEGRATION_AVAILABLE && V4IntegrationHelper.postgresql? ? false : 'requires PostgreSQL')) do
  include V4IntegrationHelper

  let(:tmp_dir) { Dir.mktmpdir('apartment_pg_schema') }
  let(:created_tenants) { [] }

  before do
    V4IntegrationHelper.ensure_test_database!
    config = V4IntegrationHelper.establish_default_connection!(tmp_dir: tmp_dir)

    Apartment.configure do |c|
      c.tenant_strategy = :schema
      c.tenants_provider = -> { [] }
      c.default_tenant = 'public'
      c.check_pending_migrations = false
    end

    Apartment.adapter = V4IntegrationHelper.build_adapter(config)
    Apartment.activate!
  end

  after do
    V4IntegrationHelper.cleanup_tenants!(created_tenants, Apartment.adapter)
    Apartment.clear_config
    Apartment::Current.reset
  end

  it 'sets search_path to the tenant schema within a switch block' do
    %w[schema_a schema_b].each do |name|
      Apartment.adapter.create(name)
      created_tenants << name
    end

    Apartment::Tenant.switch('schema_a') do
      search_path = ActiveRecord::Base.connection.select_value('SHOW search_path')
      expect(search_path).to(start_with('"schema_a"').or(start_with('schema_a')))
    end

    Apartment::Tenant.switch('schema_b') do
      search_path = ActiveRecord::Base.connection.select_value('SHOW search_path')
      expect(search_path).to(start_with('"schema_b"').or(start_with('schema_b')))
    end
  end

  context 'with persistent_schemas configured' do
    before do
      config = V4IntegrationHelper.default_connection_config

      # Create the extensions schema if it does not exist
      ActiveRecord::Base.connection.execute('CREATE SCHEMA IF NOT EXISTS extensions')

      Apartment.clear_config
      Apartment::Current.reset

      Apartment.configure do |c|
        c.tenant_strategy = :schema
        c.tenants_provider = -> { [] }
        c.default_tenant = 'public'
        c.check_pending_migrations = false
        c.configure_postgres do |pg|
          pg.persistent_schemas = ['extensions']
        end
      end

      Apartment.adapter = V4IntegrationHelper.build_adapter(config)
      Apartment.activate!
    end

    after do
      ActiveRecord::Base.connection.execute('DROP SCHEMA IF EXISTS extensions CASCADE')
    end

    it 'includes persistent schemas in the search_path after the tenant schema' do
      Apartment.adapter.create('persistent_test')
      created_tenants << 'persistent_test'

      Apartment::Tenant.switch('persistent_test') do
        search_path = ActiveRecord::Base.connection.select_value('SHOW search_path')
        # search_path should contain both the tenant and the persistent schema
        expect(search_path).to(include('persistent_test'))
        expect(search_path).to(include('extensions'))
      end
    end
  end

  it 'isolates data between schema tenants' do
    %w[data_a data_b].each do |name|
      Apartment.adapter.create(name)
      created_tenants << name

      Apartment::Tenant.switch(name) do
        V4IntegrationHelper.create_test_table!('widgets', connection: ActiveRecord::Base.connection)
      end
    end

    Apartment::Tenant.switch('data_a') do
      ActiveRecord::Base.connection.execute("INSERT INTO widgets (name) VALUES ('from_a')")
    end

    Apartment::Tenant.switch('data_b') do
      count = ActiveRecord::Base.connection.select_value('SELECT COUNT(*) FROM widgets')
      expect(count.to_i).to(eq(0))
    end

    Apartment::Tenant.switch('data_a') do
      count = ActiveRecord::Base.connection.select_value('SELECT COUNT(*) FROM widgets')
      expect(count.to_i).to(eq(1))
    end
  end

  it 'creates the schema in information_schema.schemata' do
    Apartment.adapter.create('ddl_check')
    created_tenants << 'ddl_check'

    schemas = ActiveRecord::Base.connection.select_values(
      "SELECT schema_name FROM information_schema.schemata WHERE schema_name = 'ddl_check'"
    )
    expect(schemas).to(include('ddl_check'))
  end

  it 'drops the schema and all its tables via CASCADE' do
    Apartment.adapter.create('drop_me')

    Apartment::Tenant.switch('drop_me') do
      V4IntegrationHelper.create_test_table!('widgets', connection: ActiveRecord::Base.connection)
    end

    Apartment.adapter.drop('drop_me')

    schemas = ActiveRecord::Base.connection.select_values(
      "SELECT schema_name FROM information_schema.schemata WHERE schema_name = 'drop_me'"
    )
    expect(schemas).to(be_empty)
  end

  it 'prefixes excluded model table_name with "public." for schema strategy' do
    V4IntegrationHelper.create_test_table!('global_settings', connection: ActiveRecord::Base.connection)

    stub_const('GlobalSetting', Class.new(ActiveRecord::Base) do
      self.table_name = 'global_settings'
    end)

    config = V4IntegrationHelper.default_connection_config

    Apartment.clear_config
    Apartment::Current.reset

    Apartment.configure do |c|
      c.tenant_strategy = :schema
      c.tenants_provider = -> { [] }
      c.default_tenant = 'public'
      c.excluded_models = ['GlobalSetting']
      c.check_pending_migrations = false
    end

    Apartment.adapter = V4IntegrationHelper.build_adapter(config)
    Apartment.activate!
    Apartment::Tenant.init

    expect(GlobalSetting.table_name).to(eq('public.global_settings'))
  end

  it 'keeps independent data in the same table name across schemas' do
    %w[indie_a indie_b].each do |name|
      Apartment.adapter.create(name)
      created_tenants << name

      Apartment::Tenant.switch(name) do
        V4IntegrationHelper.create_test_table!('widgets', connection: ActiveRecord::Base.connection)
      end
    end

    Apartment::Tenant.switch('indie_a') do
      ActiveRecord::Base.connection.execute("INSERT INTO widgets (name) VALUES ('alpha')")
      ActiveRecord::Base.connection.execute("INSERT INTO widgets (name) VALUES ('alpha2')")
    end

    Apartment::Tenant.switch('indie_b') do
      ActiveRecord::Base.connection.execute("INSERT INTO widgets (name) VALUES ('beta')")
    end

    Apartment::Tenant.switch('indie_a') do
      names = ActiveRecord::Base.connection.select_values('SELECT name FROM widgets ORDER BY name')
      expect(names).to(eq(%w[alpha alpha2]))
    end

    Apartment::Tenant.switch('indie_b') do
      names = ActiveRecord::Base.connection.select_values('SELECT name FROM widgets ORDER BY name')
      expect(names).to(eq(%w[beta]))
    end
  end

  # Issue #414: a tenant dropped by another process lingers as a stale positive
  # in this process's validator until its TTL. The switch then proceeds and the
  # first query hits a missing schema. The fail-safe turns that 500 into a 404.
  describe 'missing-tenant fail-safe' do
    # A real StatementInvalid (PG::UndefinedTable / 42P01) from the default
    # connection — the same error class a dropped-schema query raises.
    def undefined_table_error
      ActiveRecord::Base.connection.select_value('SELECT 1 FROM definitely_missing_xyz')
    rescue ActiveRecord::StatementInvalid => e
      e
    end

    # Wrap a cause in Apartment::ApartmentError, mirroring how ConnectionHandling
    # re-raises pool-resolution failures (the dropped-schema error can surface
    # there, wrapped, in dev when check_pending_migrations queries the gone schema).
    def wrapped_in_apartment_error(cause)
      begin
        raise(cause)
      rescue StandardError
        raise(Apartment::ApartmentError, 'Failed to resolve connection pool')
      end
    rescue Apartment::ApartmentError => e
      e
    end

    it 'distinguishes a dropped schema (gone) from a live one (a real app error)' do
      Apartment.adapter.create('failsafe_live')
      Apartment.adapter.create('failsafe_gone')
      created_tenants.push('failsafe_live', 'failsafe_gone')
      # Simulate a cross-process drop: remove the schema WITHOUT notifying this
      # process's validator, so to_regnamespace is the only ground truth.
      ActiveRecord::Base.connection.execute('DROP SCHEMA "failsafe_gone" CASCADE')

      adapter = Apartment.adapter
      expect(adapter.tenant_container_gone?(undefined_table_error, 'failsafe_gone')).to(be(true))
      expect(adapter.tenant_container_gone?(undefined_table_error, 'failsafe_live')).to(be(false))
    end

    it 'classifies a StatementInvalid wrapped in ApartmentError (pool-resolution path)' do
      Apartment.adapter.create('failsafe_wrapped')
      created_tenants << 'failsafe_wrapped'
      ActiveRecord::Base.connection.execute('DROP SCHEMA "failsafe_wrapped" CASCADE')
      wrapped = wrapped_in_apartment_error(undefined_table_error)

      expect(wrapped.cause).to(be_a(ActiveRecord::StatementInvalid)) # sanity: cause preserved
      expect(Apartment.adapter.tenant_container_gone?(wrapped, 'failsafe_wrapped')).to(be(true))
    end

    it 're-raises an ApartmentError that does not wrap a container error' do
      bare = Apartment::PendingMigrationError.new('acme')
      expect(Apartment.adapter.tenant_container_gone?(bare, 'acme')).to(be(false))
    end

    it 'returns 404 (TenantNotFound) instead of 500 when the elevator switches to a dropped schema' do
      Apartment.configure do |c|
        c.tenant_strategy = :schema
        c.default_tenant = 'public'
        c.tenants_provider = -> { ['failsafe_req'] } # validator sees it as valid (stale positive)
        c.check_pending_migrations = false
      end
      config = V4IntegrationHelper.default_connection_config(tmp_dir: tmp_dir)
      Apartment.adapter = V4IntegrationHelper.build_adapter(config)
      Apartment.activate!

      Apartment.adapter.create('failsafe_req')
      created_tenants << 'failsafe_req'
      ActiveRecord::Base.connection.execute('DROP SCHEMA "failsafe_req" CASCADE') # out-of-band drop

      app = ->(_env) { [200, {}, [ActiveRecord::Base.connection.select_value('SELECT 1 FROM some_table').to_s]] }
      elevator = Apartment::Elevators::Generic.new(app, ->(_req) { 'failsafe_req' })

      # The processor hardcodes the tenant, so the host is irrelevant — keep it a
      # valid hostname (rack 3.2+ rejects underscores in the registry part).
      expect { elevator.call(Rack::MockRequest.env_for('http://example.com/')) }
        .to(raise_error(Apartment::TenantNotFound, /failsafe_req/))
      # The stale positive is evicted, so the next request 404s without re-querying the gone schema.
      expect(Apartment.tenant_validator.call('failsafe_req')).to(be(false))
    end
  end
end
