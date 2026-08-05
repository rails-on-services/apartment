# AR connection registry thread safety — pool-per-tenant writes what Rails only reads

**Status**: designed and shipped 2026-08-05, from a reproduced failure. Scoped to
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
- **The trigger is routine, not exotic.** Rails iterates every pool at the end of
  each request or job, on every executor run, and on its own reaper timer. Parallel
  migration is the densest producer of cold creates, not the only one.
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

**The readers are Rails' own, and they run constantly:**

- `ConnectionPool::ExecutorHooks.complete` — every request and every job completion
- `ActiveRecord::QueryCache` — every executor run
- AR's `Reaper` — a background thread, on a timer
- `clear_active_connections!` / `clear_all_connections!` / `flush_idle_connections!`

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
   Apartment lock is held by Rails' executor hook, query cache, or reaper thread.
2. **They do not cover the discard half.** `Apartment.deregister_shard` →
   `remove_connection_pool` runs from the reaper's timer thread, from
   `AbstractAdapter#drop`, and from `Migrator` eviction, outside both locks.

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
discarded one takes any shard already registered in it with it.

**Shape assertion before prepending.** Both wrappers work by `super`, so a method
upstream renamed or removed would turn the wrapper into a `NoMethodError` at call
time — worse than the race. `serialize!` checks the expected method set first and
warns and skips on drift; CI's Rails-main canary surfaces it before a release.

## Design decisions

**One process-wide monitor, not per-instance.** `PoolManager` instances are few
(one per connection name), every guarded operation is an in-memory Hash op with no
IO, and prepending has to work for instances that already exist — the primary
pool's manager is built during Rails' database initializer, before `activate!`.
Per-instance locking would buy negligible parallelism in exchange for lazy-init
state on those objects, with a bootstrap race of its own.

**`Monitor`, not `Mutex`.** `each_pool_config` re-enters guarded accessors; a
non-reentrant lock would self-deadlock. Measured cost is the same (~90ns
uncontended, both).

**Snapshot-then-yield, not lock-across-yield.** Rails' iterating callers
`release_connection` and `disconnect!` inside the block. Holding the registry lock
across that would hold it across pool IO while cold creates queue behind it.
Snapshotting mirrors what `Concurrent::Map#each_pair` already does one level up
(it iterates a dup), so the two levels of the registry now have matching semantics.
Two visible consequences, both deliberate: a shard registered mid-iteration is not
yielded, and the return value is the snapshot rather than the inner Hash upstream
returns (no caller uses it).

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

## Testing

Both spec files were **verified non-vacuous by probe**: with `apply!` neutered so
the suite runs against pristine ActiveRecord, 13 of 19 unit examples and both
integration examples fail. Two artifacts of the harness were found this way and are
worth knowing about:

- **A timing-based stress test passed against unpatched ActiveRecord.** 500 inserts
  finish inside one scheduler slice, so the writer and reader never overlapped. Both
  concurrency examples were rewritten as deterministic handshakes (the reader parks
  inside its iteration block; the writer runs while it sits there).
- **The integration spec must opt out of the per-example `ConnectionHandler` swap**
  (`:stress`). That swap assigns `ActiveRecord::Base.connection_handler`, which
  lives in thread-isolated state, so threads the example spawns fall back to the
  process default and register shards in a *different* registry from the one being
  iterated. Production has one handler for all threads. Opting out means AR's
  registry outlives the example, so the spec clears tenant shards from **both**
  registries and asserts emptiness: a shard left registered makes `set_pool_config`
  *replace* a key, which MRI permits mid-iteration, and the example would pass
  unpatched.
