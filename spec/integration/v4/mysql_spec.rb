# frozen_string_literal: true

require 'spec_helper'
require 'rack'
require 'rack/mock'
require_relative 'support'

RSpec.describe('v4 MySQL integration', :integration,
               skip: (V4_INTEGRATION_AVAILABLE ? false : 'requires ActiveRecord + database gem')) do
  include V4IntegrationHelper

  before(:all) do
    skip('MySQL-only tests') unless V4IntegrationHelper.mysql?
  end

  let(:created_tenants) { [] }

  before do
    V4IntegrationHelper.ensure_test_database!
    @config = V4IntegrationHelper.establish_default_connection!

    Apartment.configure do |c|
      c.tenant_strategy = :database_name
      c.tenants_provider = -> { [] }
      c.default_tenant = 'default'
      c.check_pending_migrations = false
    end

    Apartment.adapter = V4IntegrationHelper.build_adapter(@config)
    Apartment.activate!
  end

  after do
    V4IntegrationHelper.cleanup_tenants!(created_tenants, Apartment.adapter)
    Apartment.clear_config
    Apartment::Current.reset
  end

  describe 'database creation' do
    it 'creates a tenant database visible in SHOW DATABASES' do
      Apartment.adapter.create('mysql_create_test')
      created_tenants << 'mysql_create_test'

      databases = ActiveRecord::Base.connection.select_values('SHOW DATABASES')
      expect(databases).to(include('mysql_create_test'))
    end
  end

  describe 'database drop' do
    it 'removes the tenant database from SHOW DATABASES' do
      Apartment.adapter.create('mysql_drop_test')

      databases_before = ActiveRecord::Base.connection.select_values('SHOW DATABASES')
      expect(databases_before).to(include('mysql_drop_test'))

      Apartment.adapter.drop('mysql_drop_test')

      databases_after = ActiveRecord::Base.connection.select_values('SHOW DATABASES')
      expect(databases_after).not_to(include('mysql_drop_test'))
    end
  end

  describe 'data isolation across databases' do
    before do
      %w[iso_a iso_b].each do |tenant|
        Apartment.adapter.create(tenant)
        created_tenants << tenant
        Apartment::Tenant.switch(tenant) do
          V4IntegrationHelper.create_test_table!('widgets')
        end
      end

      stub_const('Widget', Class.new(ActiveRecord::Base) { self.table_name = 'widgets' })
    end

    it 'isolates records between tenant databases' do
      Apartment::Tenant.switch('iso_a') do
        Widget.create!(name: 'Alpha')
        Widget.create!(name: 'Beta')
      end

      Apartment::Tenant.switch('iso_b') do
        expect(Widget.count).to(eq(0))
      end

      Apartment::Tenant.switch('iso_a') do
        expect(Widget.count).to(eq(2))
        expect(Widget.pluck(:name)).to(contain_exactly('Alpha', 'Beta'))
      end
    end
  end

  describe 'tables are independent per database' do
    before do
      %w[tbl_a tbl_b].each do |tenant|
        Apartment.adapter.create(tenant)
        created_tenants << tenant
        Apartment::Tenant.switch(tenant) do
          V4IntegrationHelper.create_test_table!('widgets')
        end
      end

      stub_const('Widget', Class.new(ActiveRecord::Base) { self.table_name = 'widgets' })
    end

    it 'returns correct data per database after switching' do
      Apartment::Tenant.switch('tbl_a') do
        Widget.create!(name: 'Widget A1')
        Widget.create!(name: 'Widget A2')
      end

      Apartment::Tenant.switch('tbl_b') do
        Widget.create!(name: 'Widget B1')
      end

      Apartment::Tenant.switch('tbl_a') do
        expect(Widget.count).to(eq(2))
        expect(Widget.pluck(:name)).to(contain_exactly('Widget A1', 'Widget A2'))
      end

      Apartment::Tenant.switch('tbl_b') do
        expect(Widget.count).to(eq(1))
        expect(Widget.first.name).to(eq('Widget B1'))
      end
    end
  end

  describe 'environmentified database names' do
    after do
      # Drop the environmentified database directly in case cleanup_tenants! misses it
      ActiveRecord::Base.connection.execute('DROP DATABASE IF EXISTS `test_acme`')
    end

    it 'creates a database prefixed with Rails environment' do
      Apartment.clear_config
      Apartment.configure do |c|
        c.tenant_strategy = :database_name
        c.tenants_provider = -> { [] }
        c.default_tenant = 'default'
        c.environmentify_strategy = :prepend
        c.check_pending_migrations = false
      end

      Apartment.adapter = V4IntegrationHelper.build_adapter(@config)
      Apartment.activate!

      Apartment.adapter.create('acme')
      created_tenants << 'acme'

      databases = ActiveRecord::Base.connection.select_values('SHOW DATABASES')
      expect(databases).to(include('test_acme'))
    end
  end

  describe 'resolve_connection_config' do
    it 'returns config with the correct database value' do
      resolved = Apartment.adapter.resolve_connection_config('acme')
      expect(resolved).to(be_a(Hash))
      expect(resolved['database']).to(eq('acme'))
    end

    context 'with environmentify_strategy :prepend' do
      before do
        Apartment.clear_config
        Apartment.configure do |c|
          c.tenant_strategy = :database_name
          c.tenants_provider = -> { [] }
          c.default_tenant = 'default'
          c.environmentify_strategy = :prepend
          c.check_pending_migrations = false
        end

        Apartment.adapter = V4IntegrationHelper.build_adapter(@config)
      end

      it 'returns config with environmentified database value' do
        resolved = Apartment.adapter.resolve_connection_config('acme')
        expect(resolved['database']).to(eq('test_acme'))
      end
    end
  end

  # Issue #414: a database-per-tenant drop is unambiguous — connecting to the
  # gone database raises ActiveRecord::NoDatabaseError (MySQL error 1049), so the
  # fail-safe turns the stale-positive 500 into a 404.
  describe 'missing-tenant fail-safe (database-per-tenant)' do
    def drop_database_out_of_band(name)
      conn = ActiveRecord::Base.connection
      conn.execute("DROP DATABASE IF EXISTS #{conn.quote_table_name(name)}")
    end

    it 'distinguishes a dropped database (gone) from a live one' do
      Apartment.adapter.create('mysql_fs_live')
      Apartment.adapter.create('mysql_fs_gone')
      created_tenants.push('mysql_fs_live', 'mysql_fs_gone')
      drop_database_out_of_band('mysql_fs_gone')

      err = ActiveRecord::NoDatabaseError.new('Unknown database')
      adapter = Apartment.adapter
      expect(adapter.tenant_container_gone?(err, 'mysql_fs_gone')).to(be(true))
      expect(adapter.tenant_container_gone?(err, 'mysql_fs_live')).to(be(false))
    end

    it 'does not classify a non-NoDatabaseError (missing table in a live db stays 500)' do
      Apartment.adapter.create('mysql_fs_live')
      created_tenants << 'mysql_fs_live'
      err = ActiveRecord::StatementInvalid.new("Table 'x' doesn't exist")
      expect(Apartment.adapter.tenant_container_gone?(err, 'mysql_fs_live')).to(be(false))
    end

    it 'returns 404 (TenantNotFound) when the elevator switches to a dropped database' do
      Apartment.clear_config
      Apartment.configure do |c|
        c.tenant_strategy = :database_name
        c.tenants_provider = -> { ['mysql_fs_req'] } # validator sees it as valid (stale positive)
        c.default_tenant = 'default'
        c.check_pending_migrations = false
      end
      Apartment.adapter = V4IntegrationHelper.build_adapter(@config)
      Apartment.activate!

      Apartment.adapter.create('mysql_fs_req')
      created_tenants << 'mysql_fs_req'
      drop_database_out_of_band('mysql_fs_req')

      app = ->(_env) { [200, {}, [ActiveRecord::Base.connection.select_value('SELECT 1').to_s]] }
      elevator = Apartment::Elevators::Generic.new(app, ->(_req) { 'mysql_fs_req' })

      expect { elevator.call(Rack::MockRequest.env_for('http://example.com/')) }
        .to(raise_error(Apartment::TenantNotFound, /mysql_fs_req/))
      expect(Apartment.tenant_validator.call('mysql_fs_req')).to(be(false))
    end
  end
end
