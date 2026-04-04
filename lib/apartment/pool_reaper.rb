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
      excess = @pool_manager.stats[:total_pools] - @max_total
      return 0 if excess <= 0

      candidates = @pool_manager.lru_tenants(count: excess + 1)
      evicted = 0
      candidates.each do |tenant|
        break if evicted >= excess
        next if default_tenant_pool?(tenant)

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
  end
end
