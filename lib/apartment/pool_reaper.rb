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

    private

    def stop_internal
      return unless @timer

      @timer.shutdown
      @timer.wait_for_termination(5)
      @timer = nil
    end

    def reap
      evict_idle
      evict_lru if @max_total
    rescue Apartment::ApartmentError => e
      warn "[Apartment::PoolReaper] #{e.class}: #{e.message}"
    rescue StandardError => e
      warn "[Apartment::PoolReaper] Unexpected error: #{e.class}: #{e.message}"
      warn e.backtrace&.first(5)&.join("\n") if e.backtrace
    end

    def evict_idle
      @pool_manager.idle_tenants(timeout: @idle_timeout).each do |tenant|
        next if tenant == @default_tenant

        pool = @pool_manager.remove(tenant)
        deregister_from_ar_handler(tenant)
        Instrumentation.instrument(:evict, tenant: tenant, reason: :idle)
        @on_evict&.call(tenant, pool)
      rescue StandardError => e
        warn "[Apartment::PoolReaper] Failed to evict tenant #{tenant}: #{e.class}: #{e.message}"
      end
    end

    def evict_lru
      excess = @pool_manager.stats[:total_pools] - @max_total
      return if excess <= 0

      candidates = @pool_manager.lru_tenants(count: excess + 1)
      evicted = 0
      candidates.each do |tenant|
        break if evicted >= excess
        next if tenant == @default_tenant

        pool = @pool_manager.remove(tenant)
        deregister_from_ar_handler(tenant)
        Instrumentation.instrument(:evict, tenant: tenant, reason: :lru)
        @on_evict&.call(tenant, pool)
        evicted += 1
      rescue StandardError => e
        warn "[Apartment::PoolReaper] Failed to evict tenant #{tenant}: #{e.class}: #{e.message}"
      end
    end

    def deregister_from_ar_handler(tenant)
      Apartment.deregister_shard(tenant)
    end
  end
end
