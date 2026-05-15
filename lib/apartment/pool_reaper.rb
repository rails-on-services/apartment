# frozen_string_literal: true

require 'concurrent'
require_relative 'instrumentation'

module Apartment
  # Evicts idle and excess tenant pools on a background timer.
  # Complementary to ActiveRecord's ConnectionPool::Reaper which handles
  # intra-pool connection reaping — this handles inter-pool (tenant) eviction.
  class PoolReaper
    def initialize(pool_manager:, interval:, idle_timeout:, max_total: nil,
                   default_tenant: nil, shard_key_prefix: nil, on_evict: nil)
      raise(ArgumentError, 'interval must be a positive number') unless interval.is_a?(Numeric) && interval.positive?
      unless idle_timeout.is_a?(Numeric) && idle_timeout.positive?
        raise(ArgumentError, 'idle_timeout must be a positive number')
      end
      if max_total && (!max_total.is_a?(Integer) || max_total < 1)
        raise(ArgumentError, 'max_total must be a positive integer or nil')
      end

      @pool_manager = pool_manager
      @interval = interval
      @idle_timeout = idle_timeout
      @max_total = max_total
      @default_tenant = default_tenant
      @shard_key_prefix = shard_key_prefix
      @on_evict = on_evict
      @mutex = Mutex.new
      @timer = nil
    end

    def start
      @mutex.synchronize do
        stop_internal
        @timer = Concurrent::TimerTask.new(execution_interval: @interval) { reap }
        @timer.execute
      end
      self
    end

    def stop
      @mutex.synchronize { stop_internal }
    end

    def running?
      @mutex.synchronize { @timer&.running? || false }
    end

    # Perform one synchronous eviction pass (idle + LRU).
    # Returns the total number of pools evicted.
    # Called by the background timer and by CLI `pool evict`.
    def run_cycle
      count = 0
      count += evict_idle
      count += evict_lru if @max_total
      count
    rescue Apartment::ApartmentError => e
      warn "[Apartment::PoolReaper] #{e.class}: #{e.message}"
      0
    rescue StandardError => e
      warn "[Apartment::PoolReaper] Unexpected error: #{e.class}: #{e.message}"
      warn e.backtrace&.first(5)&.join("\n") if e.backtrace
      0
    end

    private

    def stop_internal
      return unless @timer

      @timer.shutdown
      @timer.wait_for_termination(5)
      @timer = nil
    end

    def reap
      run_cycle
    end

    def evict_idle
      count = 0
      @pool_manager.idle_tenants(timeout: @idle_timeout).each do |tenant|
        next if default_tenant_pool?(tenant)
        next if protected_pool?(tenant, eviction_reason: :idle)

        pool = @pool_manager.remove(tenant)
        deregister_from_ar_handler(tenant)
        Instrumentation.instrument(:evict, tenant: tenant, reason: :idle)
        @on_evict&.call(tenant, pool)
        count += 1
      rescue StandardError => e
        warn "[Apartment::PoolReaper] Failed to evict tenant #{tenant}: #{e.class}: #{e.message}"
      end
      count
    end

    def evict_lru
      total = @pool_manager.stats[:total_pools]
      excess = total - @max_total
      return 0 if excess <= 0

      evicted = perform_lru_eviction(excess, total)

      if evicted < excess
        Instrumentation.instrument(:cap_unmet,
                                   max_total: @max_total,
                                   current: total - evicted,
                                   unevicted: excess - evicted)
      end

      evicted
    end

    # The LRU loop body, factored out so evict_lru reads as "evict up to
    # excess, then report the cap if we couldn't get there."
    # The LRU loop body, factored out so evict_lru reads as "evict up to
    # excess, then report the cap if we couldn't get there."
    def perform_lru_eviction(excess, candidate_count)
      evicted = 0
      @pool_manager.lru_tenants(count: candidate_count).each do |tenant|
        break if evicted >= excess
        next if default_tenant_pool?(tenant)
        next if protected_pool?(tenant, eviction_reason: :lru)

        pool = @pool_manager.remove(tenant)
        deregister_from_ar_handler(tenant)
        Instrumentation.instrument(:evict, tenant: tenant, reason: :lru)
        @on_evict&.call(tenant, pool)
        evicted += 1
      rescue StandardError => e
        warn "[Apartment::PoolReaper] Failed to evict tenant #{tenant}: #{e.class}: #{e.message}"
      end
      evicted
    end

    def deregister_from_ar_handler(tenant)
      Apartment.deregister_shard(tenant)
    end

    def default_tenant_pool?(pool_key)
      return false unless @default_tenant

      pool_key == @default_tenant || pool_key.start_with?("#{@default_tenant}:")
    end

    # Returns true and emits :skip_evict if the candidate pool is currently
    # protected. Used as a single guard for both eviction paths.
    def protected_pool?(tenant, eviction_reason:)
      pool = @pool_manager.peek(tenant)
      if pool_pinned?(pool)
        instrument_skip(reason: :pinned, tenant: tenant, eviction_reason: eviction_reason, pool: pool)
        return true
      end
      if pool_in_use?(pool)
        instrument_skip(reason: :in_use, tenant: tenant, eviction_reason: eviction_reason, pool: pool)
        return true
      end
      false
    end

    # True when Rails' transactional-fixture machinery has pinned the pool
    # (ConnectionPool#pin_connection!, Rails 7.1+). Evicting a pinned pool
    # strands the fixture transaction; teardown then errors or marks the DB
    # dirty. AR exposes no public predicate, so we read the ivar it sets.
    # Best-effort: callers check-then-remove, so a pool can be pinned in
    # that sub-millisecond window. Evicting one then orphans its fixture
    # transaction — a test-isolation failure (dirty fixture state, rows
    # leaking between examples), not production data corruption.
    # True when Rails' transactional-fixture machinery has pinned the pool
    # (ConnectionPool#pin_connection!, Rails 7.1+). Evicting a pinned pool
    # strands the fixture transaction; teardown then errors or marks the DB
    # dirty. AR exposes no public predicate, so we read the ivar it sets.
    # TOCTOU caveat applies — see docs/testing.md "Pool lifecycle in tests".
    def pool_pinned?(pool)
      return false unless pool&.instance_variable_defined?(:@pinned_connection)

      !pool.instance_variable_get(:@pinned_connection).nil?
    end

    # True when at least one connection is leased or holds an open
    # transaction (long migration, batch job, unpinned fixture tx). Forcing
    # eviction would potentially orphan that work, so skip and let the next
    # reap cycle re-evaluate. See docs/testing.md for the server-side-cursor
    # case this misses.
    def pool_in_use?(pool)
      return false unless pool.respond_to?(:connections)

      pool.connections.any? do |conn|
        (conn.respond_to?(:in_use?) && conn.in_use?) ||
          (conn.respond_to?(:open_transactions) && conn.open_transactions.positive?)
      end
    end

    # Build and emit the :skip_evict payload. For :in_use, include
    # connection-state details so a tenant skipped for many cycles is
    # diagnosable from instrumentation alone.
    # Build and emit the :skip_evict payload. :pinned is a binary state
    # with nothing useful to surface; :in_use carries busy_connections and
    # open_transactions so a tenant skipped for many cycles is diagnosable
    # from instrumentation alone.
    def instrument_skip(reason:, tenant:, eviction_reason:, pool:)
      payload = { tenant: tenant, reason: reason, eviction_reason: eviction_reason }
      if reason == :in_use && pool.respond_to?(:connections)
        payload[:busy_connections] = pool.connections.count do |c|
          c.respond_to?(:in_use?) && c.in_use?
        end
        payload[:open_transactions] = pool.connections.sum do |c|
          c.respond_to?(:open_transactions) ? c.open_transactions : 0
        end
      end
      Instrumentation.instrument(:skip_evict, payload)
    end
  end
end
