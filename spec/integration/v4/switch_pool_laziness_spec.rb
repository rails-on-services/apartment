# frozen_string_literal: true

require 'spec_helper'
require_relative 'support'

# Pools are created when a query resolves a connection, not when Tenant.switch
# sets Current.tenant. README's "Iterating across tenants" guidance rests on
# this: a switch whose block only enqueues a job (Redis, never the tenant
# database) costs nothing, while the same loop around a query costs one pool
# per tenant. Pinning it because the README used to claim the opposite.
RSpec.describe('v4 Tenant.switch pool laziness', :integration,
               skip: (V4_INTEGRATION_AVAILABLE ? false : 'requires ActiveRecord + database gem')) do
  include V4IntegrationHelper

  let(:tmp_dir) { Dir.mktmpdir('apartment_switch_laziness') }
  let(:tenants) { Array.new(3) { |i| "lazy_pool_#{i}" } }

  before do
    V4IntegrationHelper.ensure_test_database!
    config = V4IntegrationHelper.establish_default_connection!(tmp_dir: tmp_dir)
    V4IntegrationHelper.create_test_table!

    Apartment.configure do |c|
      c.tenant_strategy = V4IntegrationHelper.tenant_strategy
      c.tenants_provider = -> { tenants }
      c.default_tenant = V4IntegrationHelper.default_tenant
      c.pool_idle_timeout = 300
      c.check_pending_migrations = false
    end

    Apartment.adapter = V4IntegrationHelper.build_adapter(config)
    Apartment.activate!

    tenants.each do |t|
      Apartment.adapter.create(t)
      Apartment::Tenant.switch(t) do
        V4IntegrationHelper.create_test_table!('widgets', connection: ActiveRecord::Base.connection)
      end
    end
    Apartment.reset_tenant_pools!
  end

  after do
    Apartment.reset_tenant_pools!
    tenants.each { |t| Apartment.adapter.drop(t) rescue nil } # rubocop:disable Style/RescueModifier
    Apartment.clear_config
    FileUtils.remove_entry(tmp_dir) if File.directory?(tmp_dir)
  end

  it 'creates no pool for a switch whose block never queries' do
    baseline = Apartment.pool_manager.total_pools

    tenants.each { |t| Apartment::Tenant.switch(t) { :enqueued_elsewhere } }

    expect(Apartment.pool_manager.total_pools).to(eq(baseline))
  end

  it 'creates a pool for a switch whose block queries' do
    baseline = Apartment.pool_manager.total_pools

    Apartment::Tenant.switch(tenants.first) { ActiveRecord::Base.connection.select_value('SELECT 1') }

    expect(Apartment.pool_manager.total_pools).to(be > baseline)
  end
end
