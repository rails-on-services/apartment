# frozen_string_literal: true

require 'spec_helper'
require_relative 'support'

RSpec.describe('v4 Tenant lifecycle integration', :integration,
               skip: (V4_INTEGRATION_AVAILABLE ? false : 'requires ActiveRecord + database gem')) do
  include V4IntegrationHelper

  let(:tmp_dir) { Dir.mktmpdir('apartment_lifecycle') }
  let(:created_tenants) { [] }

  before do
    V4IntegrationHelper.ensure_test_database! unless V4IntegrationHelper.sqlite?
    config = V4IntegrationHelper.establish_default_connection!(tmp_dir: tmp_dir)

    Apartment.configure do |c|
      c.tenant_strategy = V4IntegrationHelper.tenant_strategy
      c.tenants_provider = -> { [] }
      c.default_tenant = V4IntegrationHelper.default_tenant
      c.check_pending_migrations = false
    end

    Apartment.adapter = V4IntegrationHelper.build_adapter(config)
    Apartment.activate!
  end

  after do
    V4IntegrationHelper.cleanup_tenants!(created_tenants, Apartment.adapter)
    Apartment.clear_config
    Apartment::Current.reset
    if V4IntegrationHelper.sqlite?
      ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
      FileUtils.rm_rf(tmp_dir)
    end
  end

  it 'creates a tenant and can switch to it' do
    Apartment.adapter.create('new_tenant')
    created_tenants << 'new_tenant'

    Apartment::Tenant.switch('new_tenant') do
      pool = ActiveRecord::Base.connection_pool
      expect(pool).to(be_a(ActiveRecord::ConnectionAdapters::ConnectionPool))
      pool.with_connection { |conn| conn.execute('SELECT 1') }
    end
  end

  it 'drops a tenant and removes its pool' do
    Apartment.adapter.create('doomed')

    Apartment::Tenant.switch('doomed') do
      ActiveRecord::Base.connection.execute('SELECT 1')
    end

    role = ActiveRecord::Base.current_role
    expect(Apartment.pool_manager.tracked?("doomed:#{role}")).to(be(true))

    Apartment.adapter.drop('doomed')

    expect(Apartment.pool_manager.tracked?("doomed:#{role}")).to(be(false))
  end

  it 'double drop does not raise' do
    Apartment.adapter.create('drop_twice')
    Apartment::Tenant.switch('drop_twice') do
      ActiveRecord::Base.connection.execute('SELECT 1')
    end

    Apartment.adapter.drop('drop_twice')
    # Second drop should not raise — adapters use IF EXISTS / rm_f
    expect { Apartment.adapter.drop('drop_twice') }.not_to(raise_error)
  end

  it 'creates the tenant storage artifact', if: V4IntegrationHelper.sqlite? do
    Apartment.adapter.create('file_check')
    created_tenants << 'file_check'

    Apartment::Tenant.switch('file_check') do
      ActiveRecord::Base.connection.execute('SELECT 1')
    end

    expected_path = File.join(tmp_dir, 'file_check.sqlite3')
    expect(File.exist?(expected_path)).to(be(true))
  end

  it 'creates a schema', if: V4IntegrationHelper.postgresql? do
    Apartment.adapter.create('lifecycle_schema')
    created_tenants << 'lifecycle_schema'

    schemas = ActiveRecord::Base.connection.select_values(
      "SELECT schema_name FROM information_schema.schemata WHERE schema_name = 'lifecycle_schema'"
    )
    expect(schemas).to(include('lifecycle_schema'))
  end

  it 'creates a database', if: V4IntegrationHelper.mysql? do
    Apartment.adapter.create('lifecycle_db')
    created_tenants << 'lifecycle_db'

    databases = ActiveRecord::Base.connection.select_values('SHOW DATABASES')
    expect(databases).to(include('lifecycle_db'))
  end
end
