# frozen_string_literal: true

# rubocop:disable ThreadSafety/NewThread, Style/CombinableLoops

require 'spec_helper'
require_relative 'support'
require 'concurrent'

RSpec.describe('v4 Stress / concurrency integration', :integration, :stress,
               skip: (V4_INTEGRATION_AVAILABLE ? false : 'requires ActiveRecord + database gem')) do
  include V4IntegrationHelper

  # ── Concurrent switching ────────────────────────────────────────────
  context 'concurrent switching' do
    let(:tmp_dir) { Dir.mktmpdir('apartment_stress') }
    let(:tenants) { Array.new(5) { |i| "stress_#{i}" } }

    before do
      V4IntegrationHelper.ensure_test_database! unless V4IntegrationHelper.sqlite?
      config = V4IntegrationHelper.establish_default_connection!(tmp_dir: tmp_dir)
      # Bump pool size so 10 concurrent threads can share a single tenant pool
      config = config.merge('pool' => 15)
      V4IntegrationHelper.create_test_table!

      stub_const('Widget', Class.new(ActiveRecord::Base) { self.table_name = 'widgets' })

      Apartment.configure do |c|
        c.tenant_strategy = V4IntegrationHelper.tenant_strategy
        c.tenants_provider = -> { tenants }
        c.default_tenant = V4IntegrationHelper.default_tenant
      end

      Apartment.adapter = V4IntegrationHelper.build_adapter(config)
      Apartment.activate!

      tenants.each do |t|
        Apartment.adapter.create(t)
        Apartment::Tenant.switch(t) { V4IntegrationHelper.create_test_table! }
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

    it 'maintains data isolation across 10 threads doing 50 switches each' do
      errors = Queue.new

      threads = Array.new(10) do |thread_idx|
        Thread.new do
          50.times do
            tenant = tenants.sample
            Apartment::Tenant.switch(tenant) do
              Widget.create!(name: "thread_#{thread_idx}")
            end
          end
        rescue StandardError => e
          errors << "Thread #{thread_idx}: #{e.class}: #{e.message}"
        end
      end
      threads.each(&:join)

      collected_errors = []
      collected_errors << errors.pop until errors.empty?
      expect(collected_errors).to(be_empty)

      # Sum across all tenants should equal 500 (10 threads * 50 writes)
      total = tenants.sum do |t|
        Apartment::Tenant.switch(t) { Widget.count }
      end
      expect(total).to(eq(500))
    end

    it 'concurrent pool creation for the same tenant does not corrupt state' do
      pools = Concurrent::Array.new
      barrier = Concurrent::CyclicBarrier.new(10)

      threads = Array.new(10) do
        Thread.new do
          barrier.wait
          Apartment::Tenant.switch('stress_0') do
            pools << ActiveRecord::Base.connection_pool.object_id
            ActiveRecord::Base.connection.execute('SELECT 1')
          end
        end
      end
      threads.each(&:join)

      # All threads should have gotten the same pool (fetch_or_create is idempotent)
      expect(pools.uniq.size).to(eq(1))
    end
  end

  # ── Many tenants — pool manager scales ──────────────────────────────
  context 'pool manager scaling' do
    let(:tmp_dir) { Dir.mktmpdir('apartment_scale') }
    let(:many_tenants) { Array.new(50) { |i| "scale_#{i}" } }

    before do
      V4IntegrationHelper.ensure_test_database! unless V4IntegrationHelper.sqlite?
      @config = V4IntegrationHelper.establish_default_connection!(tmp_dir: tmp_dir)
      V4IntegrationHelper.create_test_table!

      stub_const('Widget', Class.new(ActiveRecord::Base) { self.table_name = 'widgets' })

      Apartment.configure do |c|
        c.tenant_strategy = V4IntegrationHelper.tenant_strategy
        c.tenants_provider = -> { many_tenants }
        c.default_tenant = V4IntegrationHelper.default_tenant
      end

      Apartment.adapter = V4IntegrationHelper.build_adapter(@config)
      Apartment.activate!
    end

    after do
      many_tenants.each do |t|
        Apartment.adapter.drop(t)
      rescue StandardError
        nil
      end
      Apartment.clear_config
      Apartment::Current.reset
      if V4IntegrationHelper.sqlite?
        ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
        FileUtils.rm_rf(tmp_dir)
      end
    end

    it 'handles 50 tenants without pool corruption' do
      many_tenants.each { |t| Apartment.adapter.create(t) }

      many_tenants.each do |t|
        Apartment::Tenant.switch(t) do
          V4IntegrationHelper.create_test_table!
          Widget.create!(name: t)
        end
      end

      many_tenants.each do |t|
        Apartment::Tenant.switch(t) do
          expect(Widget.count).to(eq(1))
          expect(Widget.first.name).to(eq(t))
        end
      end

      expect(Apartment.pool_manager.stats[:total_pools]).to(eq(50))
    end
  end

  # ── PoolReaper evicts idle pools ────────────────────────────────────
  context 'pool reaper' do
    let(:tmp_dir) { Dir.mktmpdir('apartment_reaper') }

    before do
      V4IntegrationHelper.ensure_test_database! unless V4IntegrationHelper.sqlite?
    end

    after do
      begin
        Apartment.adapter&.drop('reap_me')
      rescue StandardError
        nil
      end
      Apartment.clear_config
      Apartment::Current.reset
      if V4IntegrationHelper.sqlite?
        ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
        FileUtils.rm_rf(tmp_dir)
      end
    end

    it 'evicts idle pools after timeout' do
      config = V4IntegrationHelper.establish_default_connection!(tmp_dir: tmp_dir)
      V4IntegrationHelper.create_test_table!

      Apartment.configure do |c|
        c.tenant_strategy = V4IntegrationHelper.tenant_strategy
        c.tenants_provider = -> { %w[reap_me] }
        c.default_tenant = V4IntegrationHelper.default_tenant
        c.pool_idle_timeout = 0.5
      end

      Apartment.adapter = V4IntegrationHelper.build_adapter(config)
      Apartment.activate!

      Apartment.adapter.create('reap_me')

      Apartment::Tenant.switch('reap_me') do
        ActiveRecord::Base.connection.execute('SELECT 1')
      end

      expect(Apartment.pool_manager.tracked?('reap_me')).to(be(true))

      # Wait for reaper to run (interval + idle_timeout + buffer)
      sleep(1.5)

      expect(Apartment.pool_manager.tracked?('reap_me')).to(be(false))
    end
  end

  # ── Parallel tenant creation storm ──────────────────────────────────
  context 'tenant creation storm' do
    let(:tmp_dir) { Dir.mktmpdir('apartment_storm') }
    let(:storm_tenants) { Array.new(20) { |i| "storm_#{i}" } }

    before do
      V4IntegrationHelper.ensure_test_database! unless V4IntegrationHelper.sqlite?
      config = V4IntegrationHelper.establish_default_connection!(tmp_dir: tmp_dir)
      # Bump default pool size — 20 threads all do CREATE DDL via the default connection.
      ActiveRecord::Base.establish_connection(config.merge('pool' => 25))

      Apartment.configure do |c|
        c.tenant_strategy = V4IntegrationHelper.tenant_strategy
        c.tenants_provider = -> { storm_tenants }
        c.default_tenant = V4IntegrationHelper.default_tenant
      end

      Apartment.adapter = V4IntegrationHelper.build_adapter(config.merge('pool' => 25))
      Apartment.activate!
    end

    after do
      storm_tenants.each do |t|
        Apartment.adapter.drop(t)
      rescue StandardError
        nil
      end
      Apartment.clear_config
      Apartment::Current.reset
      if V4IntegrationHelper.sqlite?
        ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
        FileUtils.rm_rf(tmp_dir)
      end
    end

    it 'handles parallel tenant creation without errors' do
      errors = Queue.new

      threads = storm_tenants.map do |t|
        Thread.new do
          Apartment.adapter.create(t)
        rescue StandardError => e
          errors << "#{t}: #{e.class}: #{e.message}"
        end
      end
      threads.each(&:join)

      collected_errors = []
      collected_errors << errors.pop until errors.empty?
      expect(collected_errors).to(be_empty)

      # Verify all tenants are accessible
      storm_tenants.each do |t|
        Apartment::Tenant.switch(t) do
          ActiveRecord::Base.connection.execute('SELECT 1')
        end
      end
    end
  end
end

# rubocop:enable ThreadSafety/NewThread, Style/CombinableLoops
