# frozen_string_literal: true

require 'spec_helper'
require_relative 'support'

# Excluded model isolation requires the ConnectionHandling patch to be aware
# of per-model connection owners. Phase 2.3's patch intercepts
# ActiveRecord::Base.connection_pool globally, so subclass connections
# established via process_excluded_models are overridden during a switch.
#
# Full excluded model support requires ConnectionHandling to check
# connection_specification_name before overriding. These tests document
# the expected behavior — pending tests will fail-loud once the fix lands.
RSpec.describe('v4 Excluded models integration', :integration,
               skip: (V4_INTEGRATION_AVAILABLE ? false : 'requires ActiveRecord + database gem')) do
  include V4IntegrationHelper

  let(:tmp_dir) { Dir.mktmpdir('apartment_excluded') }
  let(:created_tenants) { [] }

  before do
    V4IntegrationHelper.ensure_test_database! unless V4IntegrationHelper.sqlite?
    config = V4IntegrationHelper.establish_default_connection!(tmp_dir: tmp_dir)
    ActiveRecord::Base.connection.create_table(:global_settings, force: true) do |t|
      t.string(:key)
      t.string(:value)
    end
    V4IntegrationHelper.create_test_table!

    stub_const('GlobalSetting', Class.new(ActiveRecord::Base) do
      self.table_name = 'global_settings'
    end)
    stub_const('Widget', Class.new(ActiveRecord::Base) do
      self.table_name = 'widgets'
    end)

    Apartment.configure do |c|
      c.tenant_strategy = V4IntegrationHelper.tenant_strategy
      c.tenants_provider = -> { %w[tenant_a] }
      c.default_tenant = V4IntegrationHelper.default_tenant
      c.excluded_models = ['GlobalSetting']
    end

    Apartment.adapter = V4IntegrationHelper.build_adapter(config)
    Apartment.activate!
    Apartment.adapter.process_excluded_models

    Apartment.adapter.create('tenant_a')
    created_tenants << 'tenant_a'
    Apartment::Tenant.switch('tenant_a') do
      V4IntegrationHelper.create_test_table!('widgets', connection: ActiveRecord::Base.connection)
    end
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

  it 'process_excluded_models establishes a dedicated connection for the model' do
    # The excluded model should have its own connection_specification_name
    # (different from AR::Base), proving establish_connection was called.
    expect(GlobalSetting.connection_specification_name).not_to(eq(ActiveRecord::Base.connection_specification_name))
  end

  it 'process_excluded_models is idempotent' do
    expect { Apartment.adapter.process_excluded_models }.not_to(raise_error)

    expect(GlobalSetting.connection_specification_name).not_to(eq(ActiveRecord::Base.connection_specification_name))
  end

  # With schema strategy, excluded models work naturally because the public
  # schema (where global_settings lives) is accessible from any search_path.
  # With database-per-tenant strategies, ConnectionHandling overrides the
  # excluded model's pinned connection, so these are pending for non-schema.
  it 'excluded model queries always target the default database' do
    unless V4IntegrationHelper.postgresql?
      pending('ConnectionHandling does not yet respect per-model connection owners for database-per-tenant strategies')
    end

    GlobalSetting.create!(key: 'site_name', value: 'TestSite')

    Apartment::Tenant.switch('tenant_a') do
      expect(GlobalSetting.count).to(eq(1))
      expect(GlobalSetting.first.key).to(eq('site_name'))
      expect(Widget.count).to(eq(0))
    end
  end

  it 'excluded model data persists across tenant switches' do
    unless V4IntegrationHelper.postgresql?
      pending('ConnectionHandling does not yet respect per-model connection owners for database-per-tenant strategies')
    end

    GlobalSetting.create!(key: 'version', value: '1.0')

    Apartment::Tenant.switch('tenant_a') do
      expect(GlobalSetting.find_by(key: 'version').value).to(eq('1.0'))
    end

    expect(GlobalSetting.count).to(eq(1))
  end

  it 'excluded model writes inside a tenant block land in the default database' do
    unless V4IntegrationHelper.postgresql?
      pending('ConnectionHandling does not yet respect per-model connection owners for database-per-tenant strategies')
    end

    Apartment::Tenant.switch('tenant_a') do
      GlobalSetting.create!(key: 'inside_tenant', value: 'yes')
    end

    expect(GlobalSetting.find_by(key: 'inside_tenant')).to(be_present)
  end
end
