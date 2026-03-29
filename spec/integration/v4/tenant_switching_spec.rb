# frozen_string_literal: true

require 'spec_helper'
require_relative 'support'

RSpec.describe('v4 Tenant switching integration', :integration,
               skip: (V4_INTEGRATION_AVAILABLE ? false : 'requires ActiveRecord + database gem')) do
  include V4IntegrationHelper

  let(:tmp_dir) { Dir.mktmpdir('apartment_switching') }
  let(:tenants) { %w[tenant_a tenant_b] }

  before do
    V4IntegrationHelper.ensure_test_database! unless V4IntegrationHelper.sqlite?
    config = V4IntegrationHelper.establish_default_connection!(tmp_dir: tmp_dir)
    V4IntegrationHelper.create_test_table!

    stub_const('Widget', Class.new(ActiveRecord::Base) do
      self.table_name = 'widgets'
    end)

    Apartment.configure do |c|
      c.tenant_strategy = V4IntegrationHelper.tenant_strategy
      c.tenants_provider = -> { tenants }
      c.default_tenant = V4IntegrationHelper.default_tenant
    end

    Apartment.adapter = V4IntegrationHelper.build_adapter(config)
    Apartment.activate!

    tenants.each do |tenant|
      Apartment.adapter.create(tenant)
      Apartment::Tenant.switch(tenant) do
        V4IntegrationHelper.create_test_table!('widgets', connection: ActiveRecord::Base.connection)
      end
    end
  end

  after do
    V4IntegrationHelper.cleanup_tenants!(tenants, Apartment.adapter)
    Apartment.clear_config
    Apartment::Current.reset
    if V4IntegrationHelper.sqlite?
      ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
      FileUtils.rm_rf(tmp_dir)
    end
  end

  it 'isolates data between tenants' do
    Apartment::Tenant.switch('tenant_a') do
      Widget.create!(name: 'Alice Widget')
    end

    Apartment::Tenant.switch('tenant_b') do
      expect(Widget.count).to(eq(0))
    end

    Apartment::Tenant.switch('tenant_a') do
      expect(Widget.count).to(eq(1))
      expect(Widget.first.name).to(eq('Alice Widget'))
    end
  end

  it 'restores tenant context on exception' do
    expect do
      Apartment::Tenant.switch('tenant_a') do
        raise('boom')
      end
    end.to(raise_error('boom'))

    expect(Apartment::Tenant.current).to(eq(V4IntegrationHelper.default_tenant))
  end

  it 'supports nested switching' do
    Apartment::Tenant.switch('tenant_a') do
      Widget.create!(name: 'A')
      Apartment::Tenant.switch('tenant_b') do
        expect(Apartment::Tenant.current).to(eq('tenant_b'))
        Widget.create!(name: 'B')
      end
      expect(Apartment::Tenant.current).to(eq('tenant_a'))
      expect(Widget.count).to(eq(1))
    end

    Apartment::Tenant.switch('tenant_b') do
      expect(Widget.count).to(eq(1))
      expect(Widget.first.name).to(eq('B'))
    end
  end
end
