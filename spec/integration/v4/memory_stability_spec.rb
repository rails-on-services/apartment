# frozen_string_literal: true

require 'spec_helper'
require_relative 'support'

RSpec.describe('v4 Memory stability integration', :integration,
               skip: (V4_INTEGRATION_AVAILABLE ? false : 'requires ActiveRecord + database gem')) do
  include V4IntegrationHelper

  # ── Pool count stays bounded under max_total_connections ───────────
  context 'bounded pool count',
          skip: (if V4IntegrationHelper.sqlite?
                   'SQLite pool-per-tenant less meaningful with single-writer lock'
                 else
                   false
                 end) do
    let(:tmp_dir) { Dir.mktmpdir('apartment_mem_bounded') }
    let(:tenants) { Array.new(20) { |i| "mem_bounded_#{i}" } }

    before do
      V4IntegrationHelper.ensure_test_database!
      config = V4IntegrationHelper.establish_default_connection!(tmp_dir: tmp_dir)
      V4IntegrationHelper.create_test_table!

      Apartment.configure do |c|
        c.tenant_strategy = V4IntegrationHelper.tenant_strategy
        c.tenants_provider = -> { tenants }
        c.default_tenant = V4IntegrationHelper.default_tenant
        c.pool_idle_timeout = 300
        c.max_total_connections = 5
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
    end

    after do
      V4IntegrationHelper.cleanup_tenants!(tenants, Apartment.adapter)
      Apartment.clear_config
      Apartment::Current.reset
      FileUtils.rm_rf(tmp_dir)
    end

    it 'pool count stays within max_total_connections after reaper cycles' do
      stub_const('Widget', Class.new(ActiveRecord::Base) { self.table_name = 'widgets' })

      3.times do |cycle|
        tenants.each do |t|
          Apartment::Tenant.switch(t) do
            Widget.create!(name: "cycle_#{cycle}")
          end
        end

        Apartment.pool_reaper.run_cycle

        pool_count = Apartment.pool_manager.stats[:total_pools]
        expect(pool_count).to(be <= 5,
                              "Cycle #{cycle}: expected <= 5 pools, got #{pool_count}")
      end
    end
  end

  # ── Repeated create/drop doesn't leak pools ────────────────────────
  context 'create/drop cycle',
          skip: (if V4IntegrationHelper.sqlite?
                   'SQLite pool-per-tenant less meaningful with single-writer lock'
                 else
                   false
                 end) do
    let(:tmp_dir) { Dir.mktmpdir('apartment_mem_cycle') }

    before do
      V4IntegrationHelper.ensure_test_database!
      config = V4IntegrationHelper.establish_default_connection!(tmp_dir: tmp_dir)

      Apartment.configure do |c|
        c.tenant_strategy = V4IntegrationHelper.tenant_strategy
        c.tenants_provider = -> { [] }
        c.default_tenant = V4IntegrationHelper.default_tenant
        c.check_pending_migrations = false
      end

      Apartment.adapter = V4IntegrationHelper.build_adapter(config)
      Apartment.activate!
    end

    after do
      Apartment.clear_config
      Apartment::Current.reset
      FileUtils.rm_rf(tmp_dir)
    end

    it 'pool count returns to baseline after 20 create/drop cycles' do
      baseline = Apartment.pool_manager.stats[:total_pools]

      20.times do |i|
        tenant = "ephemeral_#{i}"
        Apartment.adapter.create(tenant)
        Apartment::Tenant.switch(tenant) do
          ActiveRecord::Base.connection.execute('SELECT 1')
        end
        Apartment.adapter.drop(tenant)
      end

      final = Apartment.pool_manager.stats[:total_pools]
      expect(final).to(be <= baseline + 1,
                       "Expected pool count near baseline #{baseline}, got #{final}")
    end
  end

  # ── Sustained switching without pool growth ─────────────────────────
  context 'sustained switching' do
    let(:tmp_dir) { Dir.mktmpdir('apartment_mem_sustained') }
    let(:tenants) { Array.new(5) { |i| "sustained_#{i}" } }

    before do
      V4IntegrationHelper.ensure_test_database! unless V4IntegrationHelper.sqlite?
      config = V4IntegrationHelper.establish_default_connection!(tmp_dir: tmp_dir)
      V4IntegrationHelper.create_test_table!

      Apartment.configure do |c|
        c.tenant_strategy = V4IntegrationHelper.tenant_strategy
        c.tenants_provider = -> { tenants }
        c.default_tenant = V4IntegrationHelper.default_tenant
        c.max_total_connections = 100
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

    it 'no phantom pools after 200 round-robin switches' do
      stub_const('Widget', Class.new(ActiveRecord::Base) { self.table_name = 'widgets' })

      # Prime all tenant pools
      tenants.each do |t|
        Apartment::Tenant.switch(t) { Widget.create!(name: 'prime') }
      end

      expected_pools = Apartment.pool_manager.stats[:total_pools]

      200.times do |i|
        tenant = tenants[i % tenants.size]
        Apartment::Tenant.switch(tenant) do
          ActiveRecord::Base.connection.execute('SELECT 1')
        end
      end

      final_pools = Apartment.pool_manager.stats[:total_pools]
      expect(final_pools).to(eq(expected_pools),
                             "Expected #{expected_pools} pools after 200 switches, got #{final_pools}")
    end
  end
end
