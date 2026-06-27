# frozen_string_literal: true

require 'spec_helper'
require_relative 'support'

# Proves the :reading-role test seam end to end without fixtures or RBAC:
# register_reading_role! makes connected_to(role: :reading) route a tenant
# switch to a "#{tenant}:reading" pool whose base config is inherited from the
# :reading default pool. The same-physical-DB second-role pattern that unblocks
# the fixture-pool-lifecycle :reading variants (docs/designs/reading-role-test-support.md).
RSpec.describe('v4 :reading-role routing seam', :integration,
               skip: (V4_INTEGRATION_AVAILABLE && V4IntegrationHelper.postgresql? ? false : 'requires PostgreSQL')) do
  include V4IntegrationHelper

  let(:tenant) { "reading_seam_#{SecureRandom.hex(4)}" }

  before do
    V4IntegrationHelper.ensure_test_database!
    config = V4IntegrationHelper.establish_default_connection!
    V4IntegrationHelper.register_reading_role!(config)

    Apartment.configure do |c|
      c.tenant_strategy = :schema
      c.tenants_provider = -> { [tenant] }
      c.default_tenant = 'public'
      c.check_pending_migrations = false
    end
    Apartment.adapter = V4IntegrationHelper.build_adapter(config)
    Apartment.activate!
    Apartment.adapter.create(tenant)
  end

  after do
    V4IntegrationHelper.cleanup_tenants!([tenant], Apartment.adapter)
    Apartment.clear_config
    Apartment::Current.reset
  end

  it 'registers a retrievable :reading default pool on AR::Base' do
    pool = ActiveRecord::Base.connection_handler.retrieve_connection_pool(
      'ActiveRecord::Base', role: :reading
    )
    expect(pool).not_to(be_nil)
  end

  it 'routes a switch under connected_to(role: :reading) to a "tenant:reading" pool' do
    ActiveRecord::Base.connected_to(role: :reading) do
      Apartment::Tenant.switch(tenant) { ActiveRecord::Base.connection }
    end

    expect(Apartment.pool_manager.stats[:tenants]).to(include("#{tenant}:reading"))
    expect(Apartment.pool_manager.stats[:tenants]).not_to(include("#{tenant}:writing"))
  end
end
