# frozen_string_literal: true

require 'spec_helper'
require_relative 'support'

unless defined?(Rails)
  module Rails
    def self.env
      'test'
    end
  end
end

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
        end

        Apartment.adapter = V4IntegrationHelper.build_adapter(@config)
      end

      it 'returns config with environmentified database value' do
        resolved = Apartment.adapter.resolve_connection_config('acme')
        expect(resolved['database']).to(eq('test_acme'))
      end
    end
  end
end
