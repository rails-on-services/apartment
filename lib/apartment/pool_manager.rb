# frozen_string_literal: true

require 'concurrent'

module Apartment
  class PoolManager
    def initialize
      @pools = Concurrent::Map.new
      @timestamps = Concurrent::Map.new
    end

    # Fetch an existing pool or create one via the block.
    # Timestamp is updated after pool creation to avoid orphaned timestamps if the block raises.
    def fetch_or_create(tenant_key, &)
      pool = @pools.compute_if_absent(tenant_key, &)
      touch(tenant_key)
      pool
    end

    def get(tenant_key)
      pool = @pools[tenant_key]
      touch(tenant_key) if pool
      pool
    end

    # Delete pool first, then timestamp. This ordering prevents a concurrent
    # #get from orphaning a timestamp (get checks @pools, skips touch if absent).
    def remove(tenant_key)
      pool = @pools.delete(tenant_key)
      @timestamps.delete(tenant_key)
      pool
    end

    def tracked?(tenant_key)
      @pools.key?(tenant_key)
    end

    # Returns stats for a tenant pool. Follows ActiveRecord's convention of
    # exposing computed durations (seconds_idle) rather than raw monotonic
    # timestamps, which are meaningless outside the process.
    def stats_for(tenant_key)
      return nil unless tracked?(tenant_key)

      { seconds_idle: monotonic_now - @timestamps[tenant_key] }
    end

    def idle_tenants(timeout:)
      cutoff = monotonic_now - timeout
      @timestamps.each_pair.filter_map { |key, ts| key if ts < cutoff }
    end

    def lru_tenants(count:)
      @timestamps.each_pair
        .sort_by { |_, ts| ts }
        .first(count)
        .map(&:first)
    end

    # Phase 1: basic stats. Full observability (per-tenant breakdown,
    # connection counts, eviction counters) deferred to Phase 2+.
    def stats
      {
        total_pools: @pools.size,
        tenants: @pools.keys,
      }
    end

    # Disconnect all pools before clearing to prevent connection leaks.
    # Each pool's disconnect! is individually rescued so one broken pool
    # doesn't prevent cleanup of others.
    def clear
      @pools.each_pair do |key, pool|
        pool.disconnect! if pool.respond_to?(:disconnect!)
      rescue StandardError => e
        warn "[Apartment::PoolManager] Failed to disconnect pool '#{key}': #{e.class}: #{e.message}"
      end
      @pools.clear
      @timestamps.clear
    end

    private

    def touch(tenant_key)
      @timestamps[tenant_key] = monotonic_now
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
