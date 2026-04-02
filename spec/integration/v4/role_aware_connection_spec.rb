# frozen_string_literal: true

require 'spec_helper'
require_relative 'support'
require_relative 'support/rbac_helper'

RSpec.describe('Role-aware connection routing', :integration, :postgresql_only, :rbac,
               skip: (V4_INTEGRATION_AVAILABLE && V4IntegrationHelper.postgresql? ? false : 'requires PG')) do
  include V4IntegrationHelper

  let(:tenant) { 'rbac_conn_tenant' }

  before do
    config = V4IntegrationHelper.establish_default_connection!
    RbacHelper.setup_connects_to!(config)

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
    V4IntegrationHelper.establish_default_connection!
    Apartment.adapter = V4IntegrationHelper.build_adapter(
      V4IntegrationHelper.default_connection_config
    )
    V4IntegrationHelper.cleanup_tenants!([tenant], Apartment.adapter)
    Apartment.clear_config
    Apartment::Current.reset
    RbacHelper.teardown_rbac_connections!
  end

  it 'creates separate pools per role for the same tenant' do
    writing_pool = nil
    writing_user = nil

    Apartment::Tenant.switch(tenant) do
      writing_pool = ActiveRecord::Base.connection_pool
      writing_user = ActiveRecord::Base.connection.execute('SELECT current_user AS cu').first['cu']
    end

    ActiveRecord::Base.connected_to(role: :db_manager) do
      Apartment::Tenant.switch(tenant) do
        mgr_pool = ActiveRecord::Base.connection_pool
        mgr_user = ActiveRecord::Base.connection.execute('SELECT current_user AS cu').first['cu']

        expect(mgr_pool).not_to(eq(writing_pool))
        expect(mgr_user).to(eq(RbacHelper::ROLES[:db_manager]))
        expect(writing_user).not_to(eq(mgr_user))
      end
    end
  end

  it 'uses distinct pool keys per role' do
    Apartment::Tenant.switch(tenant) { ActiveRecord::Base.connection }

    ActiveRecord::Base.connected_to(role: :db_manager) do
      Apartment::Tenant.switch(tenant) { ActiveRecord::Base.connection }
    end

    pool_keys = Apartment.pool_manager.stats[:tenants]
    expect(pool_keys).to(include("#{tenant}:writing"))
    expect(pool_keys).to(include("#{tenant}:db_manager"))
  end

  it 'propagates the db_manager username into tenant pool config' do
    ActiveRecord::Base.connected_to(role: :db_manager) do
      Apartment::Tenant.switch(tenant) do
        pool_config = ActiveRecord::Base.connection_pool.db_config.configuration_hash
        expect(pool_config[:username]).to(eq(RbacHelper::ROLES[:db_manager]))
      end
    end
  end
end
