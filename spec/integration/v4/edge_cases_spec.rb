# frozen_string_literal: true

require 'spec_helper'
require_relative 'support'

RSpec.describe('v4 Edge cases integration', :integration,
               skip: (V4_INTEGRATION_AVAILABLE ? false : 'requires ActiveRecord + database gem')) do
  include V4IntegrationHelper

  let(:tmp_dir) { Dir.mktmpdir('apartment_edge_cases') }
  let(:tenants) { %w[tenant_a tenant_b] }
  let(:extra_tenants) { [] }

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
    # Reset tenant context before cleanup to avoid being stuck in a tenant
    Apartment::Tenant.reset

    unless @tenants_cleaned
      all_tenants = tenants + extra_tenants
      V4IntegrationHelper.cleanup_tenants!(all_tenants, Apartment.adapter)
    end
    Apartment.clear_config
    Apartment::Current.reset
    if V4IntegrationHelper.sqlite?
      ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
      FileUtils.rm_rf(tmp_dir)
    end
  end

  describe 'switch! (non-block form)' do
    it 'sets tenant and resolves correct pool' do
      Apartment::Tenant.switch!('tenant_a')
      Widget.create!(name: 'via_switch_bang')
      expect(Widget.count).to(eq(1))

      Apartment::Tenant.switch!('tenant_b')
      expect(Widget.count).to(eq(0))

      Apartment::Tenant.reset
    end
  end

  describe 'switching to default tenant explicitly' do
    it 'uses the default pool' do
      Apartment::Tenant.switch('tenant_a') do
        Widget.create!(name: 'in_a')
      end

      default = V4IntegrationHelper.default_tenant
      Apartment::Tenant.switch(default) do
        expect(Apartment::Tenant.current).to(eq(default))
      end
    end
  end

  describe 'nested create inside switch' do
    it 'creating a tenant inside a switch block preserves outer tenant context' do
      Apartment::Tenant.switch('tenant_a') do
        Widget.create!(name: 'before_create')

        Apartment.adapter.create('nested_tenant')
        extra_tenants << 'nested_tenant'

        # After create returns, we should still be in tenant_a
        expect(Apartment::Tenant.current).to(eq('tenant_a'))
        expect(Widget.count).to(eq(1))
      end
    end
  end

  describe 'clear_config' do
    it 'disconnects all pools and stops the reaper' do
      Apartment::Tenant.switch('tenant_a') { Widget.create!(name: 'a') }
      Apartment::Tenant.switch('tenant_b') { Widget.create!(name: 'b') }

      expect(Apartment.pool_manager.stats[:total_pools]).to(be >= 2)
      reaper = Apartment.pool_reaper

      # Clean up tenants BEFORE clear_config destroys the adapter
      V4IntegrationHelper.cleanup_tenants!(tenants, Apartment.adapter)
      @tenants_cleaned = true

      Apartment.clear_config

      expect(Apartment.pool_manager).to(be_nil)
      expect(Apartment.pool_reaper).to(be_nil)
      expect(reaper).not_to(be_running)
    end
  end

  describe 'seed' do
    it 'loads the seed file inside the tenant context' do
      seed_file = File.join(tmp_dir, 'seeds.rb')
      File.write(seed_file, "Widget.create!(name: 'seeded')")

      # Use a dedicated tenant for seed tests to avoid conflicts with main before block.
      seed_tenant = 'seed_test'
      extra_tenants << seed_tenant

      # Reconfigure with the seed file
      config = V4IntegrationHelper.establish_default_connection!(tmp_dir: tmp_dir)
      Apartment.configure do |c|
        c.tenant_strategy = V4IntegrationHelper.tenant_strategy
        c.tenants_provider = -> { [seed_tenant] }
        c.default_tenant = V4IntegrationHelper.default_tenant
        c.seed_data_file = seed_file
      end
      Apartment.adapter = V4IntegrationHelper.build_adapter(config)
      Apartment.activate!

      Apartment.adapter.create(seed_tenant)
      Apartment::Tenant.switch(seed_tenant) do
        V4IntegrationHelper.create_test_table!('widgets', connection: ActiveRecord::Base.connection)
      end

      Apartment.adapter.seed(seed_tenant)

      Apartment::Tenant.switch(seed_tenant) do
        expect(Widget.count).to(eq(1))
        expect(Widget.first.name).to(eq('seeded'))
      end
    end

    it 'raises ConfigurationError when seed file does not exist' do
      seed_tenant = 'seed_missing_test'
      extra_tenants << seed_tenant

      config = V4IntegrationHelper.establish_default_connection!(tmp_dir: tmp_dir)
      Apartment.configure do |c|
        c.tenant_strategy = V4IntegrationHelper.tenant_strategy
        c.tenants_provider = -> { [seed_tenant] }
        c.default_tenant = V4IntegrationHelper.default_tenant
        c.seed_data_file = '/tmp/definitely_does_not_exist_xyz.rb'
      end
      Apartment.adapter = V4IntegrationHelper.build_adapter(config)
      Apartment.activate!

      Apartment.adapter.create(seed_tenant)

      expect { Apartment.adapter.seed(seed_tenant) }.to(raise_error(
                                                          Apartment::ConfigurationError, /does not exist/
                                                        ))
    end
  end

  describe 'migrate with real schema change' do
    it 'adds a column visible only in the target tenant' do
      Apartment::Tenant.switch('tenant_a') do
        ActiveRecord::Base.connection.add_column(:widgets, :color, :string)
      end

      Apartment::Tenant.switch('tenant_a') do
        Widget.reset_column_information
        expect(Widget.column_names).to(include('color'))
      end

      Apartment::Tenant.switch('tenant_b') do
        Widget.reset_column_information
        expect(Widget.column_names).not_to(include('color'))
      end

      # Reset column info so other tests aren't affected
      Widget.reset_column_information
    end
  end

  describe 'empty string tenant name' do
    it 'treats empty string as a distinct tenant value' do
      # The ConnectionHandling patch treats '' as a tenant (not nil),
      # which means it will attempt pool resolution for ''.
      # Current.tenant will be '' inside the block.
      Apartment::Tenant.switch('') do
        expect(Apartment::Tenant.current).to(eq(''))
      end
    end
  end
end
