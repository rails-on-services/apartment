# frozen_string_literal: true

require 'monitor'
require_relative '../errors'

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
    # routine and unavoidable, all via ConnectionHandler#each_connection_pool:
    # ActiveRecord::QueryCache.run on every executor run (the start of every
    # request and job), ConnectionPool::ExecutorHooks.complete on every executor
    # completion, Base.clear_query_caches_for_current_thread after writes,
    # ActiveRecord.all_open_transactions for transaction-callback bookkeeping, and
    # clear_active_connections! / clear_all_connections! /
    # flush_idle_connections!. (AR's own ConnectionPool::Reaper is NOT one of
    # them — it keeps a private WeakRef list and never reads this registry.)
    # Parallel migration is simply the densest producer of cold creates (one
    # thread per tenant, all establishing at once) and therefore the easiest place
    # to see it.
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
    # NO DEADLOCK, BY CONSTRUCTION. SYNC is a LEAF lock: every guarded body is an
    # in-memory Hash operation that acquires nothing else, performs no IO, and
    # yields to no caller. Keep it that way — it is the entire deadlock-freedom
    # argument, and Apartment's cold-create path already establishes the one lock
    # ordering that exists (Concurrent::Map's write lock, or the capped path's
    # create mutex, is taken FIRST and SYNC underneath it via
    # establish_connection). Nothing acquires SYNC and then reaches for either.
    # Upstream cooperates: +remove_pool_config+ returns the pool_config and
    # +disconnect_pool_from_pool_manager+ calls +disconnect!+ on it only after the
    # guarded call has returned, and +establish_connection+ builds the pool
    # (PoolConfig#pool, under PoolConfig's own monitor) after +set_pool_config+
    # returns — so no pool IO and no other monitor is ever nested under SYNC.
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
      # Monitor, not Mutex, purely defensively: no guarded method re-enters
      # another today (each accessor's +super+ reads the Hash directly, and
      # #each_pool_config yields outside the lock), and establish_connection's
      # several acquisitions are sequential rather than nested — a Mutex would
      # work. Reentrance costs nothing measurable here (~90ns either way) and
      # buys tolerance for an upstream implementation in which one accessor
      # dispatches through another.
      SYNC = Monitor.new

      # Every public accessor AR::ConnectionAdapters::PoolManager defines. Both
      # halves of this claim are enforced at activate! time: a method that has
      # gone missing raises, and an accessor upstream has ADDED that we therefore
      # do not guard warns (the patch still works, but there is a hole in it).
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
          serialize!(ActiveRecord::ConnectionAdapters::PoolManager, POOL_MANAGER_METHODS, PoolManagerSync,
                     exhaustive: true)
          serialize!(ActiveRecord::ConnectionAdapters::ConnectionHandler, HANDLER_METHODS, HandlerSync)
          nil
        end

        private

        # FAILS CLOSED on a shape we cannot serialize. Both wrapper modules work by
        # +super+, so a guarded method that no longer exists anywhere in the MRO
        # would be a NoMethodError at first call. Raising here instead is louder and
        # earlier: activate! runs at boot, from an explicit call, so the operator
        # learns on deploy that this gem version does not support this ActiveRecord
        # version. The alternative — warn and continue unpatched — reinstates a race
        # that fails a fraction of cold tenant switches under load, which is far
        # harder to attribute. It would also be effectively silent: the Rails-main
        # CI canary is continue-on-error, so a warning blocks nothing.
        #
        # Resolution deliberately uses +method_defined?+, not +instance_methods(false)+:
        # +super+ dispatches through the whole ancestor chain, so a method upstream
        # merely MOVED to a superclass or an included module still works through the
        # wrapper. Testing for a direct definition would refuse a refactor that is
        # entirely benign, and refusing is now fatal.
        #
        # +exhaustive+ additionally warns (never raises) when upstream has grown a
        # public accessor we do not guard: the patch still does its job, but that
        # method touches the registry unsynchronized. A warning, not a raise,
        # because a hole is strictly better than a boot failure — and the unit spec
        # pins the exact set so it fails in CI first.
        def serialize!(klass, method_names, wrapper, exhaustive: false)
          missing = method_names.reject do |name|
            klass.method_defined?(name) || klass.private_method_defined?(name)
          end

          unless missing.empty?
            raise(Apartment::ConfigurationError,
                  "Apartment cannot serialize #{klass} on ActiveRecord " \
                  "#{ActiveRecord::VERSION::STRING}: expected method(s) #{missing.join(', ')} " \
                  'are gone. Pool-per-tenant registers connection pools concurrently and ' \
                  'this registry is not thread-safe without them. Upgrade ros-apartment to a ' \
                  'version that supports this ActiveRecord release.')
          end

          warn_unguarded(klass, method_names, wrapper) if exhaustive

          klass.prepend(wrapper)
        end

        def warn_unguarded(klass, method_names, wrapper)
          # instance_methods(false) is the right question HERE (unlike above): it asks
          # what this class itself declares, and stays correct after prepending
          # because a prepended module's methods are not the class's own.
          unguarded = klass.instance_methods(false) - method_names
          return if unguarded.empty?

          warn "[Apartment] #{klass} on ActiveRecord #{ActiveRecord::VERSION::STRING} declares " \
               "method(s) #{unguarded.join(', ')} that #{wrapper.name} does not serialize. " \
               'Concurrent tenant pool creation is protected, but those methods reach the ' \
               'registry unsynchronized.'
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
        #
        # The block-less form returns an Enumerator over +__method__+ rather than
        # over an eagerly-built Array, so the snapshot is taken when enumeration
        # begins rather than when the Enumerator is created. Upstream's block-less
        # form is lazy too; nothing in Rails 7.2-8.1 uses it, and deferring is the
        # less surprising of the two if something ever does.
        def each_pool_config(role = nil, &block)
          return enum_for(__method__, role) unless block

          snapshot = []
          SYNC.synchronize { super(role) { |pool_config| snapshot << pool_config } }

          snapshot.each(&block)
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
      #
      # Declared private to match upstream. A prepended method is public by
      # default, and leaving it so would widen a Rails internal into public API
      # from a patch whose only job is a lock.
      module HandlerSync
        def set_pool_manager(...)
          SYNC.synchronize { super }
        end

        private :set_pool_manager
      end
    end
  end
end
