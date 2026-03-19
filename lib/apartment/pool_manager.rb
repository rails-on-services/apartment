# frozen_string_literal: true

require 'concurrent'

module Apartment
  class PoolManager
    def initialize
      @pools = Concurrent::Map.new
      @timestamps = Concurrent::Map.new
    end

    def fetch_or_create(tenant_key)
      touch(tenant_key)
      @pools.compute_if_absent(tenant_key) { yield }
    end

    def get(tenant_key)
      touch(tenant_key) if @pools.key?(tenant_key)
      @pools[tenant_key]
    end

    def remove(tenant_key)
      @timestamps.delete(tenant_key)
      @pools.delete(tenant_key)
    end

    def tracked?(tenant_key)
      @pools.key?(tenant_key)
    end

    def stats_for(tenant_key)
      return nil unless tracked?(tenant_key)
      { last_accessed: @timestamps[tenant_key] }
    end

    def idle_tenants(timeout:)
      cutoff = Time.now - timeout
      @timestamps.each_pair.filter_map { |key, ts| key if ts < cutoff }
    end

    def lru_tenants(count:)
      @timestamps.each_pair
                  .sort_by { |_, ts| ts }
                  .first(count)
                  .map(&:first)
    end

    def stats
      {
        total_pools: @pools.size,
        tenants: @pools.keys,
      }
    end

    def clear
      @pools.clear
      @timestamps.clear
    end

    private

    def touch(tenant_key)
      @timestamps[tenant_key] = Time.now
    end
  end
end
