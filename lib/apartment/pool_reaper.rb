# frozen_string_literal: true

require 'concurrent'
require_relative 'instrumentation'

module Apartment
  class PoolReaper
    class << self
      def start(pool_manager:, interval:, idle_timeout:, max_total: nil, default_tenant: nil, on_evict: nil)
        stop if running?

        @pool_manager = pool_manager
        @idle_timeout = idle_timeout
        @max_total = max_total
        @default_tenant = default_tenant
        @on_evict = on_evict

        @timer = Concurrent::TimerTask.new(execution_interval: interval) { reap }
        @timer.execute
      end

      def stop
        @timer&.shutdown
        @timer = nil
      end

      def running?
        @timer&.running? || false
      end

      private

      def reap
        evict_idle
        evict_lru if @max_total
      rescue => e
        warn "[Apartment::PoolReaper] Error during eviction: #{e.message}"
      end

      def evict_idle
        @pool_manager.idle_tenants(timeout: @idle_timeout).each do |tenant|
          next if tenant == @default_tenant

          pool = @pool_manager.remove(tenant)
          Instrumentation.instrument(:evict, tenant: tenant, reason: :idle)
          @on_evict&.call(tenant, pool)
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
          Instrumentation.instrument(:evict, tenant: tenant, reason: :lru)
          @on_evict&.call(tenant, pool)
          evicted += 1
        end
      end
    end
  end
end
