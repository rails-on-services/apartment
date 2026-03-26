# frozen_string_literal: true

require 'spec_helper'

RSpec.describe(Apartment::PoolReaper) do
  let(:pool_manager) { Apartment::PoolManager.new }
  let(:disconnect_calls) { Concurrent::Array.new }
  let(:on_evict) { ->(tenant, _pool) { disconnect_calls << tenant } }

  after { described_class.stop }

  describe '.start / .stop' do
    it 'can start and stop without error' do
      described_class.start(
        pool_manager: pool_manager,
        interval: 0.1,
        idle_timeout: 0.2,
        on_evict: on_evict
      )
      expect(described_class).to(be_running)
      described_class.stop
      expect(described_class).not_to(be_running)
    end
  end

  describe '.start argument validation' do
    it 'raises ArgumentError for zero interval' do
      expect { described_class.start(pool_manager: pool_manager, interval: 0, idle_timeout: 1) }
        .to(raise_error(ArgumentError, /interval/))
    end

    it 'raises ArgumentError for negative idle_timeout' do
      expect { described_class.start(pool_manager: pool_manager, interval: 1, idle_timeout: -1) }
        .to(raise_error(ArgumentError, /idle_timeout/))
    end

    it 'raises ArgumentError for non-positive max_total' do
      expect { described_class.start(pool_manager: pool_manager, interval: 1, idle_timeout: 1, max_total: 0) }
        .to(raise_error(ArgumentError, /max_total/))
    end
  end

  describe 'idle eviction' do
    it 'evicts pools idle beyond timeout' do
      pool_manager.fetch_or_create('stale') { 'pool_stale' }
      pool_manager.instance_variable_get(:@timestamps)['stale'] = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 10

      pool_manager.fetch_or_create('fresh') { 'pool_fresh' }

      described_class.start(
        pool_manager: pool_manager,
        interval: 0.05,
        idle_timeout: 1,
        on_evict: on_evict
      )

      sleep 0.2

      expect(disconnect_calls).to(include('stale'))
      expect(pool_manager.tracked?('stale')).to(be(false))
      expect(pool_manager.tracked?('fresh')).to(be(true))
    end
  end

  describe 'max_total eviction' do
    it 'evicts LRU pools when over max' do
      3.times do |i|
        pool_manager.fetch_or_create("tenant_#{i}") { "pool_#{i}" }
        pool_manager.instance_variable_get(:@timestamps)["tenant_#{i}"] =
          Process.clock_gettime(Process::CLOCK_MONOTONIC) - (300 - (i * 100))
      end

      described_class.start(
        pool_manager: pool_manager,
        interval: 0.05,
        idle_timeout: 999,
        max_total: 2,
        on_evict: on_evict
      )

      sleep 0.2

      expect(pool_manager.stats[:total_pools]).to(be <= 2)
      expect(disconnect_calls).to(include('tenant_0'))
    end
  end

  describe 'protected tenants' do
    it 'never evicts the default tenant' do
      pool_manager.fetch_or_create('public') { 'pool_default' }
      pool_manager.instance_variable_get(:@timestamps)['public'] =
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - 9999

      described_class.start(
        pool_manager: pool_manager,
        interval: 0.05,
        idle_timeout: 1,
        default_tenant: 'public',
        on_evict: on_evict
      )

      sleep 0.2

      expect(pool_manager.tracked?('public')).to(be(true))
      expect(disconnect_calls).not_to(include('public'))
    end
  end

  describe 'double start' do
    it 'stops the previous timer before starting a new one' do
      described_class.start(
        pool_manager: pool_manager,
        interval: 0.1,
        idle_timeout: 999,
        on_evict: on_evict
      )
      expect(described_class).to(be_running)

      # Start again — should not leak the old timer
      described_class.start(
        pool_manager: pool_manager,
        interval: 0.1,
        idle_timeout: 999,
        on_evict: on_evict
      )
      expect(described_class).to(be_running)
      described_class.stop
      expect(described_class).not_to(be_running)
    end
  end

  describe 'error resilience' do
    it 'continues running when on_evict callback raises' do
      bad_callback = ->(_tenant, _pool) { raise('callback explosion') }

      pool_manager.fetch_or_create('tenant_a') { 'pool_a' }
      pool_manager.instance_variable_get(:@timestamps)['tenant_a'] =
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - 10
      pool_manager.fetch_or_create('tenant_b') { 'pool_b' }
      pool_manager.instance_variable_get(:@timestamps)['tenant_b'] =
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - 10

      described_class.start(
        pool_manager: pool_manager,
        interval: 0.05,
        idle_timeout: 1,
        on_evict: bad_callback
      )

      sleep 0.3

      # Timer should still be running despite callback errors
      expect(described_class).to(be_running)
      # Both tenants should still have been removed from the pool manager
      # (the removal happens before the callback)
      expect(pool_manager.tracked?('tenant_a')).to(be(false))
      expect(pool_manager.tracked?('tenant_b')).to(be(false))
    end
  end

  describe 'instrumentation' do
    it 'emits evict.apartment events on eviction' do
      events = Concurrent::Array.new
      ActiveSupport::Notifications.subscribe('evict.apartment') { |event| events << event }

      pool_manager.fetch_or_create('stale') { 'pool_stale' }
      pool_manager.instance_variable_get(:@timestamps)['stale'] = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 10

      described_class.start(
        pool_manager: pool_manager,
        interval: 0.05,
        idle_timeout: 1,
        on_evict: on_evict
      )

      sleep(0.2)

      expect(events.any? { |e| e.payload[:tenant] == 'stale' }).to(be(true))
    ensure
      ActiveSupport::Notifications.unsubscribe('evict.apartment')
    end
  end
end
