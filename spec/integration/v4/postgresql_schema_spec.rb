# frozen_string_literal: true

require 'spec_helper'
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
    end

    Apartment.adapter = V4IntegrationHelper.build_adapter(config)
    Apartment.activate!
    Apartment.adapter.process_excluded_models

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
end
