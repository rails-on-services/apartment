# frozen_string_literal: true

require 'spec_helper'
require_relative 'support'

# tenant_pool_size sizes each per-tenant pool independently of the app's
# default pool. Defaults to nil (inherit the base pool); when set, the created
# tenant ConnectionPool's max checkout size must reflect it. See issue A and
# AbstractAdapter#apply_tenant_pool_size.
RSpec.describe('v4 tenant_pool_size', :integration,
               skip: (V4_INTEGRATION_AVAILABLE ? false : 'requires ActiveRecord + database gem')) do
  include V4IntegrationHelper

  let(:tmp_dir) { Dir.mktmpdir('apartment_pool_size') }
  let(:tenant) { 'pool_size_acme' }

  before do
    V4IntegrationHelper.ensure_test_database!
    config = V4IntegrationHelper.establish_default_connection!(tmp_dir: tmp_dir)
    V4IntegrationHelper.create_test_table!

    Apartment.configure do |c|
      c.tenant_strategy = V4IntegrationHelper.tenant_strategy
      c.tenants_provider = -> { [tenant] }
      c.default_tenant = V4IntegrationHelper.default_tenant
      c.tenant_pool_size = 3
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
    FileUtils.rm_rf(tmp_dir)
  end

  it 'sizes the created tenant pool to tenant_pool_size' do
    role = ActiveRecord::Base.current_role
    Apartment::Tenant.switch(tenant) do
      ActiveRecord::Base.connection.execute('SELECT 1')
    end

    pool = Apartment.pool_manager.peek("#{tenant}:#{role}")
    expect(pool).not_to(be_nil)
    expect(pool.size).to(eq(3))
  end
end
