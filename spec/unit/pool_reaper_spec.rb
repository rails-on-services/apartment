# frozen_string_literal: true

require 'spec_helper'

RSpec.describe(Apartment::PoolReaper) do
  let(:pool_manager) { Apartment::PoolManager.new }
  let(:disconnect_calls) { Concurrent::Array.new }
  let(:on_evict) { ->(tenant, _pool) { disconnect_calls << tenant } }
  let(:reaper) do
    described_class.new(
      pool_manager: pool_manager,
      interval: 0.05,
      idle_timeout: 1,
      on_evict: on_evict
    )
  end

  after { reaper.stop if reaper.running? }

  describe '#initialize' do
    it 'creates without starting the timer' do
      expect(reaper).not_to(be_running)
    end

    it 'raises ArgumentError for zero interval' do
      expect do
        described_class.new(pool_manager: pool_manager, interval: 0, idle_timeout: 1)
      end.to(raise_error(ArgumentError, /interval/))
    end

    it 'raises ArgumentError for negative idle_timeout' do
      expect do
        described_class.new(pool_manager: pool_manager, interval: 1, idle_timeout: -1)
      end.to(raise_error(ArgumentError, /idle_timeout/))
    end

    it 'raises ArgumentError for non-positive max_total' do
      expect do
        described_class.new(pool_manager: pool_manager, interval: 1, idle_timeout: 1, max_total: 0)
      end.to(raise_error(ArgumentError, /max_total/))
    end
  end

  describe '#start / #stop' do
    it 'can start and stop without error' do
      reaper.start
      expect(reaper).to(be_running)
      reaper.stop
      expect(reaper).not_to(be_running)
    end

    it 'stop is idempotent when not running' do
      expect { reaper.stop }.not_to(raise_error)
      expect(reaper).not_to(be_running)
    end
  end

  describe 'double start' do
    it 'stops the previous timer before starting a new one' do
      reaper.start
      expect(reaper).to(be_running)

      # Start again — should not leak the old timer
      reaper.start
      expect(reaper).to(be_running)
      reaper.stop
      expect(reaper).not_to(be_running)
    end
  end

  describe 'idle eviction' do
    it 'evicts pools idle beyond timeout' do
      pool_manager.fetch_or_create('stale') { 'pool_stale' }
      pool_manager.instance_variable_get(:@timestamps)['stale'] =
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - 10

      pool_manager.fetch_or_create('fresh') { 'pool_fresh' }

      reaper.start

      sleep 0.2

      expect(disconnect_calls).to(include('stale'))
      expect(pool_manager.tracked?('stale')).to(be(false))
      expect(pool_manager.tracked?('fresh')).to(be(true))
    end
  end

  describe 'max_total eviction' do
    let(:reaper) do
      described_class.new(
        pool_manager: pool_manager,
        interval: 0.05,
        idle_timeout: 999,
        max_total: 2,
        on_evict: on_evict
      )
    end

    it 'evicts LRU pools when over max' do
      3.times do |i|
        pool_manager.fetch_or_create("tenant_#{i}") { "pool_#{i}" }
        pool_manager.instance_variable_get(:@timestamps)["tenant_#{i}"] =
          Process.clock_gettime(Process::CLOCK_MONOTONIC) - (300 - (i * 100))
      end

      reaper.start

      sleep 0.2

      expect(pool_manager.stats[:total_pools]).to(be <= 2)
      expect(disconnect_calls).to(include('tenant_0'))
    end
  end

  describe 'pinned pool protection' do
    # A pool Rails' transactional-fixture machinery has pinned to a single
    # connection. Evicting it would strand the fixture transaction.
    def pinned_pool
      pool = Object.new
      pool.instance_variable_set(:@pinned_connection, Object.new)
      pool
    end

    it 'does not evict a pinned pool that is idle beyond timeout' do
      pool_manager.fetch_or_create('pinned') { pinned_pool }
      pool_manager.instance_variable_get(:@timestamps)['pinned'] =
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - 10

      pool_manager.fetch_or_create('stale') { 'pool_stale' }
      pool_manager.instance_variable_get(:@timestamps)['stale'] =
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - 10

      reaper.start
      sleep 0.2

      expect(pool_manager.tracked?('pinned')).to(be(true))
      expect(disconnect_calls).not_to(include('pinned'))
      expect(pool_manager.tracked?('stale')).to(be(false))
    end

    it 'does not evict a pinned pool under max_total LRU pressure' do
      lru_reaper = described_class.new(
        pool_manager: pool_manager,
        interval: 0.05,
        idle_timeout: 999,
        max_total: 1,
        on_evict: on_evict
      )

      pool_manager.fetch_or_create('pinned') { pinned_pool }
      pool_manager.instance_variable_get(:@timestamps)['pinned'] =
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - 300

      pool_manager.fetch_or_create('evictable') { 'pool_evictable' }
      pool_manager.instance_variable_get(:@timestamps)['evictable'] =
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - 100

      lru_reaper.start
      sleep 0.2
      lru_reaper.stop

      expect(pool_manager.tracked?('pinned')).to(be(true))
      expect(disconnect_calls).not_to(include('pinned'))
    end
  end

  describe 'in-use pool protection' do
    # A pool with at least one connection currently leased or holding an
    # open transaction — e.g., a long-running migration, a Sidekiq job that
    # opened a transaction, or an unpinned per-example fixture transaction.
    def in_use_pool(leased: true, open_tx: 0)
      pool = Object.new
      conn = Object.new
      conn.define_singleton_method(:in_use?) { leased }
      conn.define_singleton_method(:open_transactions) { open_tx }
      pool.define_singleton_method(:connections) { [conn] }
      pool
    end

    it 'does not evict a pool with a leased connection idle beyond timeout' do
      pool_manager.fetch_or_create('busy') { in_use_pool(leased: true) }
      pool_manager.instance_variable_get(:@timestamps)['busy'] =
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - 10

      pool_manager.fetch_or_create('stale') { in_use_pool(leased: false) }
      pool_manager.instance_variable_get(:@timestamps)['stale'] =
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - 10

      reaper.start
      sleep 0.2

      expect(pool_manager.tracked?('busy')).to(be(true))
      expect(disconnect_calls).not_to(include('busy'))
      expect(pool_manager.tracked?('stale')).to(be(false))
    end

    it 'does not evict a pool with an open transaction (no formal pin)' do
      pool_manager.fetch_or_create('tx_open') { in_use_pool(leased: false, open_tx: 1) }
      pool_manager.instance_variable_get(:@timestamps)['tx_open'] =
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - 10

      reaper.start
      sleep 0.2

      expect(pool_manager.tracked?('tx_open')).to(be(true))
      expect(disconnect_calls).not_to(include('tx_open'))
    end

    it 'does not evict an in-use pool under max_total LRU pressure' do
      lru_reaper = described_class.new(
        pool_manager: pool_manager,
        interval: 0.05,
        idle_timeout: 999,
        max_total: 1,
        on_evict: on_evict
      )

      pool_manager.fetch_or_create('busy') { in_use_pool(leased: true) }
      pool_manager.instance_variable_get(:@timestamps)['busy'] =
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - 300

      pool_manager.fetch_or_create('evictable') { in_use_pool(leased: false) }
      pool_manager.instance_variable_get(:@timestamps)['evictable'] =
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - 100

      lru_reaper.start
      sleep 0.2
      lru_reaper.stop

      expect(pool_manager.tracked?('busy')).to(be(true))
      expect(disconnect_calls).not_to(include('busy'))
    end

    it 'evicts the pool on a later cycle once connections are released' do
      flag = { leased: true }
      live_pool = Object.new
      conn = Object.new
      conn.define_singleton_method(:in_use?) { flag[:leased] }
      conn.define_singleton_method(:open_transactions) { 0 }
      live_pool.define_singleton_method(:connections) { [conn] }

      pool_manager.fetch_or_create('transient') { live_pool }
      pool_manager.instance_variable_get(:@timestamps)['transient'] =
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - 10

      reaper.start
      sleep 0.15
      expect(pool_manager.tracked?('transient')).to(be(true))

      flag[:leased] = false
      pool_manager.instance_variable_get(:@timestamps)['transient'] =
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - 10
      sleep 0.15

      expect(pool_manager.tracked?('transient')).to(be(false))
      expect(disconnect_calls).to(include('transient'))
    end
  end

  describe 'protected tenants' do
    let(:reaper) do
      described_class.new(
        pool_manager: pool_manager,
        interval: 0.05,
        idle_timeout: 1,
        default_tenant: 'public',
        on_evict: on_evict
      )
    end

    it 'never evicts the default tenant' do
      pool_manager.fetch_or_create('public') { 'pool_default' }
      pool_manager.instance_variable_get(:@timestamps)['public'] =
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - 9999

      reaper.start

      sleep 0.2

      expect(pool_manager.tracked?('public')).to(be(true))
      expect(disconnect_calls).not_to(include('public'))
    end
  end

  describe 'default tenant composite key guard' do
    let(:reaper) do
      described_class.new(
        pool_manager: pool_manager,
        interval: 0.05,
        idle_timeout: 1,
        default_tenant: 'public',
        on_evict: on_evict
      )
    end

    it 'never evicts pools whose keys start with the default tenant prefix' do
      pool_manager.fetch_or_create('public:writing') { 'pool_pw' }
      pool_manager.fetch_or_create('public:reading') { 'pool_pr' }
      pool_manager.instance_variable_get(:@timestamps)['public:writing'] =
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - 9999
      pool_manager.instance_variable_get(:@timestamps)['public:reading'] =
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - 9999

      reaper.start

      sleep 0.2

      expect(pool_manager.tracked?('public:writing')).to(be(true))
      expect(pool_manager.tracked?('public:reading')).to(be(true))
      expect(disconnect_calls).not_to(include('public:writing'))
      expect(disconnect_calls).not_to(include('public:reading'))
    end
  end

  describe 'error resilience' do
    let(:bad_callback) { ->(_tenant, _pool) { raise('callback explosion') } }
    let(:reaper) do
      described_class.new(
        pool_manager: pool_manager,
        interval: 0.05,
        idle_timeout: 1,
        on_evict: bad_callback
      )
    end

    it 'continues running when on_evict callback raises' do
      pool_manager.fetch_or_create('tenant_a') { 'pool_a' }
      pool_manager.instance_variable_get(:@timestamps)['tenant_a'] =
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - 10
      pool_manager.fetch_or_create('tenant_b') { 'pool_b' }
      pool_manager.instance_variable_get(:@timestamps)['tenant_b'] =
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - 10

      reaper.start

      sleep 0.3

      # Timer should still be running despite callback errors
      expect(reaper).to(be_running)
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
      pool_manager.instance_variable_get(:@timestamps)['stale'] =
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - 10

      reaper.start

      sleep(0.2)

      expect(events.any? { |e| e.payload[:tenant] == 'stale' }).to(be(true))
    ensure
      ActiveSupport::Notifications.unsubscribe('evict.apartment')
    end

    it 'emits skip_evict.apartment with reason :pinned when a pinned pool is preserved' do
      events = Concurrent::Array.new
      ActiveSupport::Notifications.subscribe('skip_evict.apartment') { |e| events << e }

      pinned = Object.new
      pinned.instance_variable_set(:@pinned_connection, Object.new)
      pool_manager.fetch_or_create('pinned') { pinned }
      pool_manager.instance_variable_get(:@timestamps)['pinned'] =
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - 10

      reaper.start
      sleep(0.2)

      pinned_skip = events.find { |e| e.payload[:tenant] == 'pinned' }
      expect(pinned_skip).not_to(be_nil)
      expect(pinned_skip.payload).to(include(reason: :pinned, eviction_reason: :idle))
    ensure
      ActiveSupport::Notifications.unsubscribe('skip_evict.apartment')
    end

    it 'emits skip_evict.apartment with reason :in_use including connection state' do
      events = Concurrent::Array.new
      ActiveSupport::Notifications.subscribe('skip_evict.apartment') { |e| events << e }

      busy = Object.new
      conn = Object.new
      conn.define_singleton_method(:in_use?) { true }
      conn.define_singleton_method(:open_transactions) { 2 }
      busy.define_singleton_method(:connections) { [conn] }
      pool_manager.fetch_or_create('busy') { busy }
      pool_manager.instance_variable_get(:@timestamps)['busy'] =
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - 10

      reaper.start
      sleep(0.2)

      busy_skip = events.find { |e| e.payload[:tenant] == 'busy' }
      expect(busy_skip).not_to(be_nil)
      expect(busy_skip.payload).to(include(reason: :in_use, eviction_reason: :idle,
                                           busy_connections: 1, open_transactions: 2))
    ensure
      ActiveSupport::Notifications.unsubscribe('skip_evict.apartment')
    end

    it 'emits cap_unmet.apartment when protected pools prevent LRU eviction from reaching max_total' do
      events = Concurrent::Array.new
      ActiveSupport::Notifications.subscribe('cap_unmet.apartment') { |e| events << e }

      lru_reaper = described_class.new(
        pool_manager: pool_manager,
        interval: 0.05,
        idle_timeout: 999,
        max_total: 1,
        on_evict: on_evict
      )

      pinned = Object.new
      pinned.instance_variable_set(:@pinned_connection, Object.new)
      pool_manager.fetch_or_create('pinned_a') { pinned }
      pool_manager.fetch_or_create('pinned_b') { pinned }
      pool_manager.instance_variable_get(:@timestamps)['pinned_a'] =
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - 300
      pool_manager.instance_variable_get(:@timestamps)['pinned_b'] =
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - 200

      lru_reaper.start
      sleep(0.2)
      lru_reaper.stop

      cap_event = events.last
      expect(cap_event).not_to(be_nil)
      expect(cap_event.payload).to(include(max_total: 1))
      expect(cap_event.payload[:current]).to(be >= 2)
      expect(cap_event.payload[:unevicted]).to(be_positive)
    ensure
      ActiveSupport::Notifications.unsubscribe('cap_unmet.apartment')
    end
  end

  describe '#run_cycle' do
    it 'performs one synchronous eviction pass and returns eviction count' do
      pool_manager.fetch_or_create('stale_a') { 'pool_a' }
      pool_manager.fetch_or_create('stale_b') { 'pool_b' }
      pool_manager.instance_variable_get(:@timestamps)['stale_a'] =
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - 10
      pool_manager.instance_variable_get(:@timestamps)['stale_b'] =
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - 10
      pool_manager.fetch_or_create('fresh') { 'pool_fresh' }

      count = reaper.run_cycle
      expect(count).to(eq(2))
      expect(pool_manager.tracked?('stale_a')).to(be(false))
      expect(pool_manager.tracked?('stale_b')).to(be(false))
      expect(pool_manager.tracked?('fresh')).to(be(true))
    end

    it 'returns 0 when nothing to evict' do
      pool_manager.fetch_or_create('fresh') { 'pool_fresh' }
      count = reaper.run_cycle
      expect(count).to(eq(0))
    end

    it 'does not require the background timer to be running' do
      expect(reaper).not_to(be_running)
      pool_manager.fetch_or_create('stale') { 'pool_stale' }
      pool_manager.instance_variable_get(:@timestamps)['stale'] =
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - 10

      count = reaper.run_cycle
      expect(count).to(eq(1))
    end

    it 'respects default_tenant protection' do
      protected_reaper = described_class.new(
        pool_manager: pool_manager,
        interval: 0.05,
        idle_timeout: 1,
        default_tenant: 'public',
        on_evict: on_evict
      )
      pool_manager.fetch_or_create('public') { 'pool_default' }
      pool_manager.instance_variable_get(:@timestamps)['public'] =
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - 9999
      pool_manager.fetch_or_create('stale') { 'pool_stale' }
      pool_manager.instance_variable_get(:@timestamps)['stale'] =
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - 10

      count = protected_reaper.run_cycle
      expect(count).to(eq(1))
      expect(pool_manager.tracked?('public')).to(be(true))
      expect(pool_manager.tracked?('stale')).to(be(false))
    end
  end
end
