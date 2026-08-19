# frozen_string_literal: true

require 'concurrent'

module Apartment
  class PoolManager
    # Set by Apartment.configure to the PoolReaper when max_total_connections is
    # configured. nil (no cap) keeps the lock-free compute_if_absent fast path.
    attr_accessor :admission_controller

    def initialize
      @pools = Concurrent::Map.new
      @timestamps = Concurrent::Map.new
      @create_mutex = Mutex.new
      @admission_controller = nil
    end

    # Fetch an existing pool or create one via the block.
    # Timestamp is updated after pool creation to avoid orphaned timestamps if the block raises.
    # When an admission controller is wired (a cap is configured), cold creates
    # go through the bounded path so the pool count cannot exceed max_total.
    def fetch_or_create(tenant_key, &)
      return fetch_or_admit(tenant_key, &) if @admission_controller

      touch_and_return(tenant_key, @pools.compute_if_absent(tenant_key, &))
    end

    def get(tenant_key)
      pool = @pools[tenant_key]
      touch(tenant_key) if pool
      pool
    end

    # Read a pool without updating its idle timestamp. PoolReaper uses this
    # to inspect an eviction candidate; +get+ would reset the very idleness
    # the reaper is measuring.
    def peek(tenant_key)
      @pools[tenant_key]
    end

    # Delete pool first, then timestamp. This ordering prevents a concurrent
    # #get from orphaning a timestamp (get checks @pools, skips touch if absent).
    #
    # @api private
    # Forgetting a pool here is only HALF of discarding it — the pool stays
    # registered in AR's ConnectionHandler, leaking the registration and a live
    # backend if the tenant is never re-accessed. Callers outside the gem want
    # Apartment.deregister_shard (one pool) or Apartment.reset_tenant_pools! (all).
    # These mutators also bypass PoolReaper's in-use guard: they will drop a pool
    # with a checked-out connection or an open transaction.
    # See docs/designs/out-of-band-tenant-ddl.md.
    #
    # ACCEPTED LIMITATION, the check-then-act race. A caller that guards a discard with
    # Apartment.pool_in_use? — AbstractAdapter#discard_ddl_role_pool is the one in the
    # gem — reads "not in use" and then calls Apartment.deregister_shard, and another
    # thread can lease a connection from that pool in between. The guard narrows the
    # window; it does not close it.
    #
    # It cannot be closed here. Leasing does not go through this map: a thread that
    # already holds the pool object leases from the object directly, so no lock this
    # class could take would serialize the two. Closing it would need a lock inside
    # ActiveRecord's pool, which is not ours to add.
    #
    # Two things bound the exposure. Migrator leases eagerly rather than lazily, which
    # its own comment explains as closing a capture->lease window — so the pool a
    # migration will use is already in use by the time a concurrent discard could look
    # at it. And #evict_by_role, which Migrator calls at the end of a run, has no in-use
    # check at all: the race class is pre-existing and strictly wider there, so a guarded
    # discard is an improvement on the surrounding code rather than a new hazard.
    def remove(tenant_key)
      pool = @pools.delete(tenant_key)
      @timestamps.delete(tenant_key)
      pool
    end

    # @api private — see #remove.
    def remove_tenant(tenant)
      prefix = "#{tenant}:"
      removed = []
      @pools.each_key do |key|
        next unless key.start_with?(prefix)

        pool = remove(key)
        removed << [key, pool] if pool
      end
      removed
    end

    # @api private — see #remove.
    def evict_by_role(role)
      suffix = ":#{role}"
      removed = []
      @pools.each_key do |key|
        next unless key.end_with?(suffix)

        pool = remove(key)
        removed << [key, pool] if pool
      end
      removed
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

    # Basic stats. Full observability (per-tenant breakdown, connection
    # counts, eviction counters) deferred to Phase 3.
    def stats
      {
        total_pools: @pools.size,
        tenants: @pools.keys,
      }
    end

    # Yields each tracked pool as +[tenant_key, pool]+. Snapshot semantics
    # follow Concurrent::Map#each_pair: keys observed during iteration are
    # those present at the time the iterator visits them. Read-only; do not
    # mutate the manager from inside the block.
    def each_pair(&)
      @pools.each_pair(&)
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

    # Capacity-bounded creation path. Serializes cold creates so the admission
    # controller's capacity check + eviction + insert is atomic across creators;
    # the new pool is only inserted after admit! confirms (or makes) room. The
    # hot path (existing pool) stays lock-free in fetch_or_create. Establishing
    # the connection under the lock is deliberate: it serializes only cold
    # creates (once per tenant per worker) — the price of a hard count bound.
    def fetch_or_admit(tenant_key)
      existing = @pools[tenant_key]
      return touch_and_return(tenant_key, existing) if existing

      @create_mutex.synchronize do
        cached = @pools[tenant_key]
        return touch_and_return(tenant_key, cached) if cached

        @admission_controller.admit!(tenant_key)
        pool = yield
        @pools[tenant_key] = pool
        touch_and_return(tenant_key, pool)
      end
    end

    def touch_and_return(tenant_key, pool)
      touch(tenant_key)
      pool
    end

    def touch(tenant_key)
      @timestamps[tenant_key] = monotonic_now
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
