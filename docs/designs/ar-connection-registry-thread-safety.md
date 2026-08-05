# AR connection registry thread safety — pool-per-tenant writes what Rails only reads

**Status**: designed and shipped 2026-08-05, from a reproduced failure. Ships in
`4.0.0.alpha11`. Scoped to
`Apartment::Patches::ConnectionRegistry`; complements
[`v4-connection-model-rationale.md`](v4-connection-model-rationale.md) (why pools
are per-tenant) and [`phase-2.3-connection-handling.md`](phase-2.3-connection-handling.md)
(how routing resolves them).

## Verdict

- **A cold tenant switch can fail outright**, with
  `RuntimeError: can't add a new key into hash during iteration` raised inside the
  switch and surfaced as `Apartment::ApartmentError`. Reproduced end-to-end on
  SQLite, PostgreSQL, and MySQL. See [Evidence](#evidence).
- **ActiveRecord's pool registry is an unsynchronized nested Hash.** Rails writes
  it only at boot and reads it forever after; pool-per-tenant writes it for the
  life of the process, from whichever thread first routes to a tenant. See
  [Mechanism](#mechanism).
- **The trigger is routine, not exotic.** Rails iterates every pool at the start
  and end of every request and job, and after writes. Parallel migration is the
  densest producer of cold creates, not the only one.
- **No deadlock, by construction**: the monitor is a leaf lock — nothing is
  acquired under it, no IO happens under it, and no caller's block runs under it.
  See [Design decisions](#design-decisions).
- **Apartment's existing locks do not cover it.** They serialize cold creates
  against each other, which is the wrong side of the race. See
  [Why the existing locks miss it](#why-the-existing-locks-miss-it).
- **Fix: serialize the registry itself** — one process-wide monitor around AR's
  `PoolManager` accessors, with iteration snapshotting under the lock and yielding
  outside it. ~90ns per registry operation. See [The fix](#the-fix).
- **Safe by construction on unrecognized Rails versions**: the patch asserts the
  upstream method set before prepending, and warns and skips if it drifted.

## Contents

- [Evidence](#evidence)
- [Mechanism](#mechanism)
- [Why the existing locks miss it](#why-the-existing-locks-miss-it)
- [The fix](#the-fix)
- [Design decisions](#design-decisions)
- [Not covered](#not-covered)
- [Testing](#testing)

## Evidence

Measured, not reasoned. Each row is a deterministic overlap: a thread parks inside
`ActiveRecord::Base.connection_handler.each_connection_pool` and the tenant work
runs while it sits there.

| Scenario | Without the patch | With the patch |
|---|---|---|
| Cold `Tenant.switch` (SQLite / PG / MySQL) | `ApartmentError: … can't add a new key into hash during iteration` | Switch succeeds |
| `Migrator.new(threads: 2).run` | Per-tenant `Result` status `:failed`, same error | `run.success?` |
| Same-thread mutate during iteration | `RuntimeError` from AR's `PoolManager` | Registers; snapshot yielded |
| Reaper-side discard during iteration | (delete is permitted mid-iteration) | Unchanged |

Regression coverage: `spec/unit/patches/connection_registry_spec.rb` (19 examples;
13 fail against pristine ActiveRecord) and
`spec/integration/v4/connection_registry_spec.rb` (2 examples; both fail against
pristine ActiveRecord on SQLite, PostgreSQL, and MySQL).

## Mechanism

**`ActiveRecord::ConnectionAdapters::PoolManager` stores every pool Rails knows
about in a plain nested Hash** — `{ role => { shard => pool_config } }`, built as
`Hash.new { |h, k| h[k] = {} }`, with no synchronization. Identical in Rails 7.2,
8.0, and 8.1.

**Rails can afford that because upstream only writes it at boot.**
`establish_connection` runs from initializers and from `connects_to`,
single-threaded; afterwards the structure is effectively read-only.

**v4 cannot.** A tenant pool is established lazily by the thread that first routes
to that tenant, so every cold switch calls `set_pool_config` and adds a shard key —
at an arbitrary moment in the life of the process.

**MRI's iteration guard then fails the writer, not the reader.** The guard lives on
the Hash object, not on the thread, so a `[]=` that adds a key while any thread is
inside `each_value` raises. The exception lands in the tenant switch: the request
that happened to be first to touch a tenant is the one that breaks.

**The readers are Rails' own, and they run constantly** — all of them through
`ConnectionHandler#each_connection_pool`:

| Caller | When |
|---|---|
| `ActiveRecord::QueryCache.run` | every executor run — start of every request and job |
| `ConnectionPool::ExecutorHooks.complete` | every executor completion; calls `release_connection` in-block |
| `Base.clear_query_caches_for_current_thread` | after writes |
| `ActiveRecord.all_open_transactions` | transaction-callback bookkeeping |
| `clear_active_connections!` / `clear_all_connections!` / `flush_idle_connections!` | boot and on demand |

**Not** AR's `ConnectionPool::Reaper`: it keeps a private `WeakRef` list per reaping
frequency and never touches this registry. (An earlier draft of this doc claimed it
did.)

**Reads can write, too.** `get_pool_config`, `pool_configs`, and
`each_pool_config(role)` reach the outer Hash through `[]`, whose default proc
inserts an empty shard map on a miss. A lookup for a not-yet-seen role is itself a
mutation — which is why the guarded set is every public accessor, not only the
obvious mutators.

## Why the existing locks miss it

Cold creates are already serialized **against each other**, two different ways:

- **Uncapped path** — `Concurrent::Map#compute_if_absent` holds the map's write
  lock across the create block on the MRI backend.
- **Capped path** — `PoolManager#fetch_or_admit` holds its own create mutex (see
  [`pool-admission-control.md`](pool-admission-control.md)).

Neither helps, for two independent reasons:

1. **They exclude writers from writers; the race is writer-versus-reader.** No
   Apartment lock is held by Rails' executor hooks or query cache.
2. **They do not cover the discard half.** `Apartment.deregister_shard` →
   `remove_connection_pool` runs from Apartment's own `PoolReaper` timer thread,
   from `AbstractAdapter#drop`, and from `Migrator` eviction, outside both locks.

The registry is the only place that sees all of it, which is why the fix belongs
there rather than at Apartment's call sites.

## The fix

`Apartment::Patches::ConnectionRegistry`, applied from `Apartment.activate!`:

**`PoolManagerSync`** prepends `ActiveRecord::ConnectionAdapters::PoolManager` and
wraps all eight public accessors in a shared `Monitor`. `each_pool_config`
additionally **collects its pool_configs under the lock and yields outside it**.

**`HandlerSync`** prepends `ActiveRecord::ConnectionAdapters::ConnectionHandler` and
wraps `set_pool_manager`, whose `||=` on a `Concurrent::Map` is atomic per
operation but a read-then-write across two — so two threads establishing the first
connection for one connection name can each build a `PoolManager`, and the
discarded one takes any shard already registered in it with it. Redeclared
`private` to match upstream: a prepended method is public by default, and leaving it
so would widen a Rails internal into public API from a patch whose only job is a
lock.

**Shape check before prepending — fails closed.** Both wrappers work by `super`, so
a guarded method that exists nowhere in the MRO would be a `NoMethodError` at first
call. `serialize!` therefore **raises `Apartment::ConfigurationError`** at
`activate!` naming the missing methods and the Rails version. Warning and continuing
unpatched was the first design and is wrong: it reinstates a race that fails a
fraction of cold tenant switches under load — much harder to attribute than a boot
failure — and it would be effectively silent, since the Rails-main CI canary is
`continue-on-error`.

Resolution uses `method_defined?` / `private_method_defined?`, **not**
`instance_methods(false)`. `super` dispatches through the whole ancestor chain, so a
method upstream merely *moved* to a superclass or an included module still works
through the wrapper. Testing for a direct definition would refuse a benign refactor
— and refusing is now fatal. (The original `instance_methods(false)` check had
exactly that bug.)

Separately, `serialize!` **warns** when upstream has *grown* a public accessor the
patch does not guard: the patch still works, but that method reaches the registry
unsynchronized. A warning rather than a raise, because a hole beats a boot failure —
and the unit spec pins the exact method set, so CI fails first.

## Design decisions

**One process-wide monitor, not per-instance.** `PoolManager` instances are few
(one per connection name), every guarded operation is an in-memory Hash op with no
IO, and prepending has to work for instances that already exist — the primary
pool's manager is built during Rails' database initializer, before `activate!`.
Per-instance locking would buy negligible parallelism in exchange for lazy-init
state on those objects, with a bootstrap race of its own.

**`Monitor`, not `Mutex` — defensive, not required.** No guarded method re-enters
another today: each accessor's `super` reads the Hash directly, `each_pool_config`
yields outside the lock, and `establish_connection`'s several acquisitions are
sequential rather than nested. A `Mutex` would work. Reentrance costs nothing
measurable (~90ns either way) and buys tolerance for an upstream implementation in
which one accessor dispatches through another. (An earlier draft claimed the
reentrancy already existed; it does not.)

**A leaf lock — this is the whole deadlock argument.** Every guarded body is an
in-memory Hash operation that acquires no other lock, performs no IO, and yields to
no caller. One lock ordering exists and Apartment's cold-create path fixes it:
`Concurrent::Map`'s write lock (or the capped path's create mutex) is taken first,
and `SYNC` underneath it via `establish_connection`. Nothing acquires `SYNC` and
then reaches for either. Upstream cooperates on both mutation paths:
`remove_pool_config` *returns* the `pool_config` and
`disconnect_pool_from_pool_manager` calls `disconnect!` on it only after the guarded
call returned; `establish_connection` builds the pool (`PoolConfig#pool`, under
`PoolConfig`'s own `MonitorMixin`) only after `set_pool_config` returned. If a future
change nests anything under `SYNC`, that invariant is what breaks.

Scope note: this says nothing about Apartment's *own* create lock, which **is** held
across IO. `fetch_or_create`'s `Concurrent::Map` write lock (or the capped path's
create mutex) spans the whole create block, and `establish_connection` inside it can
`disconnect!` a stale registration. That predates this patch and does not involve
`SYNC`; the claim here is only that the registry monitor never is.

**Contended cost is measured, not assumed.** 500 tenant pools, 8 threads calling
`get_pool_config` in a loop, plus one thread continuously snapshotting the whole
registry — 7,290 full 500-entry passes during the run, against roughly two per
request in reality:

| | p50 | p99 | max |
|---|---|---|---|
| Unpatched | 70ns | 70ns | 120ns |
| Patched | 150ns | 165ns | 260ns |

So the tail stays bounded in nanoseconds under deliberately unrealistic snapshot
pressure; no convoy effect appears, which is expected — the GVL already serializes
these Hash operations, so a preempted lock holder is no worse than a preempted
`Hash#[]`. The snapshotter itself pays: 18,597 passes unpatched vs 7,290 patched.
Irrelevant at two passes per request.

**Snapshot-then-yield, not lock-across-yield.** Rails' iterating callers
`release_connection` and `disconnect!` inside the block. Holding the registry lock
across that would hold it across pool IO while cold creates queue behind it.
Snapshotting mirrors what `Concurrent::Map#each_pair` already does one level up
(it iterates a dup), so the two levels of the registry now have matching semantics.
One visible consequence, deliberate: a shard registered mid-iteration is not
yielded.

**The return value stays upstream's.** A lock is no reason to narrow the contract of
the method it wraps — and this is a `:nodoc:` internal that other gems wrap too, so a
gratuitous difference costs more than it saves. Measured identical on 7.2 / 8.0 /
8.1:

| Call | Upstream returns |
|---|---|
| block, no role | the outer role map (the same object it walked) |
| block, role | the inner shard map |
| block-less, no role | the outer role map — having enumerated nothing |
| block-less, role | an `Enumerator` |

The block form now returns whatever `super` returned; the block-less form delegates
untouched. That form is also the one with nothing to serialize: upstream traverses
nothing at call time, so no concurrent write has an iteration to collide with. The
residual, named rather than papered over: the `Enumerator` handed back for a role
reads the live Hash if iterated later, exactly as upstream's would. Nothing in
ActiveRecord or in this project's bundle calls it that way (verified by grep over the
installed gems); AR's only caller,
`ConnectionHandler#each_connection_pool`, always passes a block and discards the
result.

An earlier version of this patch returned its snapshot `Array` for every block form
and an `Enumerator` for every block-less one — diverging from upstream in three of
the four cases. Four regression examples pin the table above.

One asymmetry worth recording: a `pool_config` removed after the snapshot is still
yielded, where a live Hash walk might have skipped it. Removal means `disconnect!`,
not destruction, and every iterating caller already has to tolerate acting on a pool
another thread just disconnected, so this widens an existing window rather than
opening a new one.

**Collected via `super`, not by reading the ivar.** The snapshot is exactly what
upstream would have yielded on this Rails version, so the patch carries no copy of
upstream's traversal.

**Applied from `activate!`, not at gem load.** An app that merely has the gem in
its Gemfile should not pay for a lock it does not need. (Contrast
`PostgresqlSequenceName`, which must load early because memoization can fire during
boot.)

**Wrapped with argument forwarding for `set_pool_manager`.** Its signature is
version-dependent — Rails ≥ 8.0 passes a `ConnectionDescriptor` where 7.2 passed
the connection-name String — and the key derivation is upstream's business.

## Not covered

**`establish_connection`'s get-then-set is still two operations.** Upstream reads
`get_pool_config` and then calls `set_pool_config`; each is now atomic, the pair is
not. Apartment serializes same-key cold creates itself, so two threads never race
the same shard key through Apartment's path. A host app or gem establishing the
same role/shard concurrently would still interleave — upstream's own exposure,
unchanged.

**The outer connection-name map needs nothing.** It is a `Concurrent::Map` whose
`each_pair` iterates a duplicate, so registering a new connection name during
iteration cannot trip the same guard. Only the lost-update window is real, and
`HandlerSync` closes it.

**JRuby / TruffleRuby are not the motivation.** Without a GVL, concurrent plain-Hash
writes can corrupt rather than raise, and `Concurrent::Map`'s lock-free backend
would not serialize Apartment's creates either — so the patch matters more there,
not less. Untested: the CI matrix is MRI-only.

**`PoolConfig::INSTANCES` is not the same bug.** Rails registers every `PoolConfig`
in a process-wide `ObjectSpace::WeakMap` at `initialize`, unsynchronized, and
`discard_pools!` / `disconnect_all!` iterate it — the same "Rails writes at boot,
Apartment writes forever" shape. Probed: `WeakMap` does **not** raise when a key is
added during `each_key`, so MRI's iteration guard does not apply. Nothing further to
do. (`PoolConfig` itself is `MonitorMixin`-guarded on `pool` / `disconnect!` /
`discard_pool!`.)

**`ActiveRecord::Base.configurations` is untouched.** The routing patch builds a
`HashConfig` and hands it to `establish_connection`; `DatabaseConfigurations#resolve`
returns a `DatabaseConfig` as-is, so nothing is appended to the global collection at
runtime. Verified, not assumed.

**Per-model schema memoization is a real sibling, out of scope here.**
`ModelSchema#load_schema!` memoizes `@columns_hash` / `@attribute_types` per model
class, process-wide, from whichever tenant's connection touches the model first —
the same failure *class* as the `Model.sequence_name` memoization that
[`PostgresqlSequenceName`](../../lib/apartment/patches/postgresql_sequence_name.rb)
exists for (and that v3 lost in #356). It is monitor-synchronized upstream, so it
does not crash; the exposure is a drifted or un-migrated tenant poisoning the column
set for every tenant. Not a registry race and not fixed here — tracked separately.

**Per-pool schema cache is per-pool.** `SchemaReflection` / `SchemaCache` use plain
Hashes with no lock, but each tenant pool has its own `PoolConfig` and therefore its
own reflection, so the concurrency is *within* one tenant's pool — identical to
Rails' own single-pool exposure, not something pool-per-tenant introduces.

## Follow-ups

**Upstream is the long-term home.** The bug is not Apartment-specific: any gem or
app that calls `establish_connection` after boot from more than one thread —
horizontal-sharding tooling included — hits the same unsynchronized Hash. Until a
Rails fix lands (synchronize `PoolManager` internally, snapshot before yielding),
this patch is a maintained fork of two Rails internals whose failure mode on drift
is a hard boot error. Filing that issue/PR is not yet done.

## Testing

Both spec files were **verified non-vacuous by two probes**, not one:

1. **Against pristine ActiveRecord** (`apply!` neutered): 13 of 22 unit examples and
   both integration examples fail.
2. **Against the plausible wrong implementation** — `each_pool_config` holding the
   monitor across the caller's block instead of snapshotting: 5 unit examples fail.
   This probe is why the concurrency examples assert that the mutating thread
   finished *while the reader was still parked* (`join` bounded, result checked)
   rather than merely that it eventually succeeded without error. The weaker
   assertion passed the lock-across-yield implementation on the strength of a
   five-second stall.

Three artifacts of the harness were found this way and are worth knowing about:

- **A timing-based stress test passed against unpatched ActiveRecord.** 500 inserts
  finish inside one scheduler slice, so the writer and reader never overlapped. Both
  concurrency examples were rewritten as deterministic handshakes (the reader parks
  inside its iteration block; the writer runs while it sits there).
- **Ignoring a `Thread#join` return value re-hides what the handshake exposed.** A
  thread that was blocked for the full timeout, then released, then succeeded, is
  indistinguishable from one that was never blocked — unless the join is asserted.
  Every worker thread in both specs is now bounded-joined and its `#value` checked,
  so an exception inside it fails the example instead of vanishing.
- **The integration spec must opt out of the per-example `ConnectionHandler` swap**
  (`:stress`). That swap assigns `ActiveRecord::Base.connection_handler`, which
  lives in thread-isolated state, so threads the example spawns fall back to the
  process default and register shards in a *different* registry from the one being
  iterated. Production has one handler for all threads. Opting out means AR's
  registry outlives the example, so the spec clears tenant shards from **both**
  registries and asserts emptiness: a shard left registered makes `set_pool_config`
  *replace* a key, which MRI permits mid-iteration, and the example would pass
  unpatched.
