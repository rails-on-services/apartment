# frozen_string_literal: true

require 'monitor'

module Apartment
  module Patches
    # Serializes access to ActiveRecord's connection registry so pool-per-tenant
    # can register and discard shards from many threads at once.
    #
    # THE REGISTRY. ActiveRecord::ConnectionAdapters::PoolManager (the Rails
    # class, not Apartment's same-named one) indexes every pool AR knows about as
    # a plain nested Hash, +{ role => { shard => pool_config } }+, with no
    # synchronization of any kind. Rails can afford that because upstream writes
    # it only at boot: +establish_connection+ runs from initializers and from
    # +connects_to+, single-threaded, and after boot the structure is read-only.
    #
    # WHY v4 CANNOT. A tenant pool is established lazily, on the thread that
    # first routes to that tenant, for the life of the process — so every cold
    # tenant switch adds a shard key to that Hash while other threads are reading
    # it. MRI's per-Hash iteration guard turns the collision into a hard failure
    # in the WRITER: `RuntimeError: can't add a new key into hash during
    # iteration`, surfaced by Apartment as a failed tenant switch. The readers are
    # routine and unavoidable — ConnectionPool::ExecutorHooks.complete iterates
    # every pool at the end of each request or job, ActiveRecord::QueryCache
    # iterates on every executor run, and AR's own Reaper thread iterates on a
    # timer. Parallel migration is simply the densest producer of cold creates
    # (one thread per tenant, all establishing at once) and therefore the easiest
    # place to see it.
    #
    # A read can write, too: +get_pool_config+ / +pool_configs+ /
    # +each_pool_config+ reach the outer Hash through +[]+, whose default proc
    # (+Hash.new { |h, k| h[k] = {} }+) INSERTS an empty shard map on a miss. So a
    # lookup for a not-yet-seen role is itself a write, and the guarded set below
    # is every public accessor rather than only the obvious mutators.
    #
    # WHY NOT JUST LOCK APARTMENT'S OWN CALL SITES. Apartment's cold creates are
    # already serialized against each other — Concurrent::Map's MRI backend holds
    # a write lock across +compute_if_absent+, and the capacity-bounded path holds
    # PoolManager's own create mutex. Neither excludes AR's readers, which is the
    # side of the race that matters, and neither covers the discard half
    # (+remove_connection_pool+ from the reaper thread, from AbstractAdapter#drop,
    # from Migrator eviction). The registry itself is the only place that sees all
    # of it.
    #
    # SCOPE. Applied from +Apartment.activate!+, not at gem load: an app that
    # merely has the gem in its Gemfile should not pay for a lock it does not
    # need. Prepending affects instances already created (the primary pool's
    # manager is built during Rails' database initializer, before activate!),
    # which is why the lock is module-level rather than per-instance state.
    #
    # COST. One uncontended monitor acquire, measured at ~90ns, on registry
    # operations only. +get_pool_config+ is the hot one (AR resolves it per query
    # for default-tenant and pinned traffic), where it is noise against even a
    # cached query. Iteration copies its pool_config list under the lock and
    # yields outside it, so per-request hooks hold the lock for the length of a
    # Hash walk and never for the length of a caller's block.
    module ConnectionRegistry
      # One monitor for every registry in the process. Instances are few (one per
      # connection name, so typically one or two) and every guarded operation is
      # an in-memory Hash op with no IO and no yielding, so per-instance locks
      # would buy negligible parallelism in exchange for lazy-init state on
      # objects that already exist by the time the patch is applied.
      #
      # Monitor, not Mutex: #each_pool_config re-enters through the guarded
      # accessors, and a non-reentrant lock would self-deadlock there.
      SYNC = Monitor.new

      # Every public accessor AR::ConnectionAdapters::PoolManager defines. Asserted
      # against the real class by spec, so a method added or removed upstream
      # fails the suite instead of silently leaving a hole.
      POOL_MANAGER_METHODS = %i[
        shard_names
        role_names
        pool_configs
        each_pool_config
        remove_role
        remove_pool_config
        get_pool_config
        set_pool_config
      ].freeze

      HANDLER_METHODS = %i[set_pool_manager].freeze

      class << self
        # Idempotent — prepend on an already-prepended module is a no-op.
        def apply!
          serialize!(ActiveRecord::ConnectionAdapters::PoolManager, POOL_MANAGER_METHODS, PoolManagerSync)
          serialize!(ActiveRecord::ConnectionAdapters::ConnectionHandler, HANDLER_METHODS, HandlerSync)
          nil
        end

        private

        # Refuses to patch a class whose shape we do not recognize. Both wrapper
        # modules work by +super+, so a method that upstream renamed or removed
        # would turn our wrapper into a NoMethodError at call time — worse than
        # the race. Warn and skip instead: the Rails-main canary in CI surfaces
        # the drift while released Rails versions keep working.
        def serialize!(klass, method_names, wrapper)
          missing = method_names - klass.instance_methods(false) - klass.private_instance_methods(false)

          if missing.any?
            warn "[Apartment] Skipping #{wrapper.name}: unrecognized #{klass} shape " \
                 "(missing #{missing.join(', ')}). Concurrent tenant pool creation is " \
                 'not serialized on this ActiveRecord version.'
            return
          end

          klass.prepend(wrapper)
        end
      end

      # Guards AR::ConnectionAdapters::PoolManager. Fully qualified everywhere
      # because the bare constant would resolve to Apartment::PoolManager.
      module PoolManagerSync
        def shard_names
          SYNC.synchronize { super }
        end

        def role_names
          SYNC.synchronize { super }
        end

        def pool_configs(role = nil)
          SYNC.synchronize { super }
        end

        def remove_role(role)
          SYNC.synchronize { super }
        end

        def remove_pool_config(role, shard)
          SYNC.synchronize { super }
        end

        def get_pool_config(role, shard)
          SYNC.synchronize { super }
        end

        def set_pool_config(role, shard, pool_config)
          SYNC.synchronize { super }
        end

        # Snapshot under the lock, yield outside it. Holding the registry lock
        # across the caller's block is what makes this dangerous rather than
        # merely slow: AR's own iterating callers disconnect pools and release
        # connections inside the block, so the lock would be held across pool
        # IO while cold creates queue behind it.
        #
        # Collected by delegating to +super+ rather than by reading the Hash, so
        # the snapshot is exactly what upstream would have yielded on this Rails
        # version. Two visible consequences, both deliberate: a shard registered
        # mid-iteration is not yielded (a snapshot, like Concurrent::Map's
        # iterators elsewhere in Apartment), and the return value is the snapshot
        # rather than the inner Hash upstream returns — no caller uses it.
        def each_pool_config(role = nil, &block)
          snapshot = []
          SYNC.synchronize { super(role) { |pool_config| snapshot << pool_config } }

          block ? snapshot.each(&block) : snapshot.each
        end
      end

      # Guards the handler's manager cache. +set_pool_manager+ upserts with
      # +||=+ on a Concurrent::Map: atomic per operation, but a read-then-write
      # across two, so two threads establishing the first connection for the same
      # connection name can each build a PoolManager and one is discarded —
      # silently taking any shard already registered in it with it. Serializing
      # the whole method makes the upsert atomic.
      #
      # Wrapped with argument forwarding rather than a reimplementation because
      # the signature is version-dependent (AR >= 8.0 passes a ConnectionDescriptor
      # where 7.2 passed the connection-name String) and the key derivation is
      # upstream's business, not ours.
      module HandlerSync
        def set_pool_manager(...)
          SYNC.synchronize { super }
        end
      end
    end
  end
end
