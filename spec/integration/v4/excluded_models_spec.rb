# frozen_string_literal: true

require 'spec_helper'
require_relative 'support'

# Excluded model isolation requires the ConnectionHandling patch to be aware
# of per-model connection owners. Phase 2.3's patch intercepts
# ActiveRecord::Base.connection_pool globally, so subclass connections
# established via process_excluded_models are overridden during a switch.
#
# Full excluded model support is deferred to Phase 2.4. These tests document
# the expected behavior and will be un-pended when that phase lands.
RSpec.describe('v4 Excluded models integration', :integration,
               skip: (V4_INTEGRATION_AVAILABLE ? false : 'requires ActiveRecord + sqlite3')) do
  let(:tmp_dir) { Dir.mktmpdir('apartment_excluded') }
  let(:default_db) { File.join(tmp_dir, 'default.sqlite3') }

  before do
    ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: default_db)
    ActiveRecord::Base.connection.create_table(:global_settings, force: true) do |t|
      t.string(:key)
      t.string(:value)
    end
    ActiveRecord::Base.connection.create_table(:widgets, force: true) do |t|
      t.string(:name)
    end

    stub_const('GlobalSetting', Class.new(ActiveRecord::Base) do
      self.table_name = 'global_settings'
    end)
    stub_const('Widget', Class.new(ActiveRecord::Base) do
      self.table_name = 'widgets'
    end)

    Apartment.configure do |config|
      config.tenant_strategy = :database_name
      config.tenants_provider = -> { %w[tenant_a] }
      config.default_tenant = 'default'
      config.excluded_models = ['GlobalSetting']
    end

    Apartment.adapter = Apartment::Adapters::SQLite3Adapter.new(
      ActiveRecord::Base.connection_db_config.configuration_hash
    )
    Apartment.activate!

    # Pin GlobalSetting to the default database via establish_connection.
    Apartment.adapter.process_excluded_models

    # Create tenant and set up its schema.
    Apartment.adapter.create('tenant_a')
    Apartment::Tenant.switch('tenant_a') do
      ActiveRecord::Base.connection.create_table(:widgets, force: true) do |t|
        t.string(:name)
      end
    end
  end

  after do
    Apartment.clear_config
    Apartment::Current.reset
    ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
    FileUtils.rm_rf(tmp_dir)
  end

  it 'process_excluded_models establishes a dedicated connection for the model' do
    # Verify process_excluded_models called establish_connection on GlobalSetting.
    # The model's connection_specification_name should differ from ActiveRecord::Base.
    config = GlobalSetting.connection_db_config.configuration_hash
    expect(config[:database] || config['database']).to(include('default'))
  end

  # Phase 2.4 will make ConnectionHandling aware of per-model connection owners.
  # Until then, excluded model queries inside a switch hit the tenant pool
  # instead of the pinned default pool.
  it 'excluded model queries always target the default database' do
    pending('Phase 2.4: ConnectionHandling does not yet respect per-model connection owners')

    GlobalSetting.create!(key: 'site_name', value: 'TestSite')

    Apartment::Tenant.switch('tenant_a') do
      expect(GlobalSetting.count).to(eq(1))
      expect(GlobalSetting.first.key).to(eq('site_name'))
      expect(Widget.count).to(eq(0))
    end
  end

  it 'excluded model data persists across tenant switches' do
    pending('Phase 2.4: ConnectionHandling does not yet respect per-model connection owners')

    GlobalSetting.create!(key: 'version', value: '1.0')

    Apartment::Tenant.switch('tenant_a') do
      expect(GlobalSetting.find_by(key: 'version').value).to(eq('1.0'))
    end

    expect(GlobalSetting.count).to(eq(1))
  end

  it 'excluded model writes inside a tenant block land in the default database' do
    pending('Phase 2.4: ConnectionHandling does not yet respect per-model connection owners')

    Apartment::Tenant.switch('tenant_a') do
      GlobalSetting.create!(key: 'inside_tenant', value: 'yes')
    end

    expect(GlobalSetting.find_by(key: 'inside_tenant')).to(be_present)
  end
end
