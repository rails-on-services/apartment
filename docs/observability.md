# Observability

Apartment emits `ActiveSupport::Notifications` events for every significant pool
and tenant lifecycle moment, and exposes `PoolManager#stats` for gauge sampling.
`Apartment::PoolObserver` wires both into a single sink-agnostic subscriber so you
can forward metrics to any backend without writing the subscription boilerplate
yourself.

The gem ships no transport. Counters arrive through events; gauges arrive through
the optional periodic sampler. Your `sink` proc maps `Sample` objects to whatever
backend you use.

## Event catalog

All events are namespaced `<name>.apartment` and published through
`ActiveSupport::Notifications`.

| Event | When fired | Payload keys |
|---|---|---|
| `create.apartment` | After a tenant schema/database is created | `tenant:` |
| `drop.apartment` | After a tenant schema/database is dropped | `tenant:` |
| `evict.apartment` | After a tenant pool is removed from the pool manager | `tenant:`, `reason:` (`:idle`, `:lru`, `:admission`) |
| `cap_unmet.apartment` | When the pool cap cannot be met by eviction (soft-cap breach) | `max_total:`, `current:`, `unevicted:` |
| `skip_evict.apartment` | When a candidate pool is skipped during eviction | `tenant:`, `reason:` (`:pinned`, `:in_use`), `eviction_reason:` (`:idle`, `:lru`, `:admission`); plus `busy_connections:` and `open_transactions:` when `reason: :in_use` |
| `reaper_stopped.apartment` | When the background reaper is deactivated in the test environment | `reason:` (`:test_env`) |
| `transaction_taint.apartment` | When a tenant connection is checked in while in an aborted transaction (PostgreSQL `PQTRANS_INERROR`) and is reset | `tenant:`, `pool_key:`, `open_transactions:`, `healed:` |
| `migrate_tenant.apartment` | After migrations run for one tenant (or the primary) | `tenant:`, `versions:` (array of migration version integers) |
| `migrate_tenant_failed.apartment` | When a tenant (or the primary) migration raises | `tenant:`, `error:` (the raised exception), `duration:` (seconds) |

### `transaction_taint.apartment` — what to do when it fires

**This event means the gem repaired something your application broke.** A statement failed
inside a transaction that ActiveRecord did not unwind, leaving the connection in
PostgreSQL's aborted-transaction state, where every subsequent statement raises
`PG::InFailedSqlTransaction`. Apartment reset the connection as it returned to the pool, so
the tenant keeps working. The event is the part that matters: the code that caused it is
still there.

**Why the gem bothers.** ActiveRecord's own health check cannot see this state (`active?`
probes with an empty query, which does not error in an aborted transaction), so without the
reset the poisoned connection is handed to the next caller. Under pool-per-tenant it is that
tenant's *only* connection — so the tenant would be dead on that worker until the process
restarts, while every other tenant looks fine.

**Find the call site and contain it** with `ActiveRecord::Base.transaction(requires_new: true)`,
which bounds the failure to a savepoint. Usual causes: a statement issued outside any
transaction block while one is open (raw `execute`, DDL), an error rescued *inside* a
transaction block and swallowed, or a thread killed mid-rollback.

**Alert on a rising count, not on presence.** A steady trickle is an application bug worth
fixing; a spike means a code path is poisoning connections on every request. `healed: false`
does not occur today — the key exists so a future detect-only mode needs no new event.

**Never respond by writing a raw `ROLLBACK` loop of your own.** It destroys the *enclosing*
transaction while ActiveRecord still believes its stack is intact, raises nothing, and lets
subsequent writes autocommit. See [testing.md](testing.md) for the reproduction.

**To disable the reset** (the event goes with it): `config.heal_tainted_connections = false`.
PostgreSQL-only in effect; MySQL and SQLite have no equivalent state.

> **`PoolObserver` does not forward the migrate events.** The observer below covers
> pool-lifecycle events only; `migrate_tenant` / `migrate_tenant_failed` are not in
> its counter set. Installing it alone does **not** close migration error tracking —
> subscribe to `migrate_tenant_failed.apartment` directly. Keep that subscriber
> non-raising: it runs inline on the migration thread (a worker thread under
> parallel migration). A subscriber raising a `StandardError` is isolated by the
> Migrator — logged and swallowed, not propagated (you lose that one notification,
> not the run). Process-control exceptions (`SystemExit`, `Interrupt`) and bare
> `Exception` subclasses are **not** swallowed and will surface. The **success**
> event `migrate_tenant.apartment` is *not* isolated — a raising success subscriber
> can still break the run — so keep both subscribers defensive.

**`cap_unmet` fires on two paths:** from the synchronous admission path (when a
new pool would breach the cap and no idle pool can be freed) and from the
background LRU reaper (when excess pools remain after a reap cycle). The payload
is identical on both paths.

**`skip_evict` reason detail:** `:pinned` means Rails' transactional-fixture
machinery has pinned the pool (`@pinned_connection` is set). `:in_use` means at
least one connection is leased or holds an open transaction; `busy_connections`
and `open_transactions` are included in the payload only for `:in_use` so the
skip is diagnosable from instrumentation without inspecting the pool.

## `PoolManager#stats`

```ruby
Apartment.pool_manager.stats
# => { total_pools: 12, tenants: ["acme:writing", "beta:writing", ...] }
```

`total_pools` is the count of live tenant pools in the process. `tenants` is the
full list of pool keys (formatted as `"<tenant>:<role>"`).

Per-pool idle time is available via `stats_for`:

```ruby
Apartment.pool_manager.stats_for("acme:writing")
# => { seconds_idle: 47.3 }
# => nil  (when the pool is not tracked)
```

`seconds_idle` is computed from a monotonic clock (`Process::CLOCK_MONOTONIC`);
it reflects elapsed time since the pool was last accessed, not a wall-clock
timestamp. Calling `stats_for` for an untracked key returns `nil`.

## `Apartment::PoolObserver` recipe

### Install once per process

Wire the observer in an `after_initialize` hook so it subscribes after the app
boots:

```ruby
# config/initializers/apartment_observability.rb

$apartment_observer = Apartment::PoolObserver.install!(
  sink: ->(sample) { MyMetrics.record(sample) },
  sample_interval: 60,            # seconds between gauge passes; omit/nil to disable (a non-positive value warns)
  backend_count: -> { ActiveRecord::Base.connection_pool.connections.size }
)
```

`install!` returns the observer. Store it somewhere accessible so you can call
`stop!` on shutdown (see teardown below).

The `sink` runs **inline on the thread that emitted the event** — for `evict` /
`cap_unmet` / `skip_evict` that can be the reaper thread or, during admission, a
request thread holding the pool-creation lock. Keep the sink **non-blocking**:
enqueue to your metrics client and return. A sink that does slow synchronous I/O
will stall pool reaping/admission. (It never *raises* into the gem — failures are
rescued — but it can *block*.)

#### Preforking servers (Puma cluster, Unicorn, Sidekiq with preload)

The gauge sampler runs on a background thread, and **threads do not survive
`fork`**. If you call `install!` with a `sample_interval` in `after_initialize`,
the sampler starts in the master process and is dead in every forked worker —
counters keep firing (notification subscriptions are inherited), but
`tenant_pools_live` / `backend_connections` silently flatline.

Split the two concerns: subscribe once at boot, start the sampler per worker.

```ruby
# config/initializers/apartment_observability.rb
$apartment_observer = Apartment::PoolObserver.new(
  sink: ->(sample) { MyMetrics.record(sample) },
  backend_count: -> { ActiveRecord::Base.connection_pool.connections.size }
)
$apartment_observer.subscribe!   # inherited across fork — safe to do at boot

# config/puma.rb
on_worker_boot { $apartment_observer.start_sampler!(interval: 60) }
```

Don't call `install!` again per worker — `subscribe!` is not idempotent, so a
second subscription would double-count every counter.

### `Sample` shape

Every `sink` call receives one `Sample`:

```ruby
Apartment::PoolObserver::Sample
# Data.define(:name, :kind, :value, :dimensions, :payload)
```

| Field | Type | Meaning |
|---|---|---|
| `name` | `Symbol` | Metric identity — see names below |
| `kind` | `:counter` or `:gauge` | How to record it |
| `value` | `Numeric` | Always `1` for counters; the measured value for gauges |
| `dimensions` | `Hash` | Curated subset of payload suitable for metric tags |
| `payload` | `Hash` | Raw notification payload (counters) or `{}` (gauges) |

**Counter names** (one per event, `value: 1`): `:create`, `:evict`,
`:cap_unmet`, `:skip_evict`, `:reaper_stopped`.

**Gauge names** (from the periodic sampler): `:tenant_pools_live` (`value` =
`PoolManager#stats[:total_pools]`), `:backend_connections` (`value` = your
`backend_count` callable result; omitted when the callable returns `nil`).

**Checkout-pressure gauges** (per pass, from each tenant pool's AR
`ConnectionPool#stat`): `:pools_waiting` (count of pools with threads blocked on
checkout — the same-tenant fan-out starvation signal), `:pools_saturated` (count
with `busy >= size`), and `:max_checkout_waiting` (the worst pool's `waiting`
count). The offending tenant is carried in `:max_checkout_waiting`'s **payload**,
not as a metric dimension, to avoid unbounded time-series churn — promote it to a
dimension only in a sink you know can absorb the cardinality.

These gauges are sampled **instantaneously** (not peak-held), so a short
starvation episode can fall between passes. Use a short `sample_interval` (5–10s)
on Sidekiq/job roles to catch sustained same-tenant fan-out; keep web at the
default if desired. They show *pressure*, not lossless timeout accounting —
standard APM captures the resulting `ActiveRecord::ConnectionTimeoutError` itself.

**Dimensions** are curated for cardinality. `reason:` is promoted from payload
into `dimensions` for any counter event that carries it (currently `:evict`,
`:skip_evict`, and `:reaper_stopped`). Everything else stays in `payload`.

### Wiring a sink

```ruby
sink = lambda do |sample|
  tags = sample.dimensions.map { |k, v| "#{k}:#{v}" }

  case sample.kind
  when :counter
    MyMetrics.increment(sample.name, tags: tags)
  when :gauge
    MyMetrics.gauge(sample.name, sample.value, tags: tags)
  end
end

$apartment_observer = Apartment::PoolObserver.install!(sink: sink)
```

### Alerting in the sink

Branch on `sample.name` for operational alerts:

```ruby
sink = lambda do |sample|
  # ... normal recording ...

  case sample.name
  when :cap_unmet
    # Pool budget is being breached; investigate tenant_pool_size or the
    # max_tenant_pools / max_tenant_connections ceiling.
    MyAlerts.trigger(:pool_cap_breach, payload: sample.payload)
  when :skip_evict
    # A pool is being skipped repeatedly; may indicate a long-running transaction.
    if sample.payload[:reason] == :in_use
      MyAlerts.trigger(:pool_eviction_skipped,
                       tenant: sample.payload[:tenant],
                       open_transactions: sample.payload[:open_transactions])
    end
  end
end
```

### `backend_count` seam

Supply `backend_count` as a callable that returns the total connection count from
your backend (connection pool, proxy, or database driver). The observer calls it
on each gauge pass and emits a `:backend_connections` gauge. Return `nil` to skip
the sample for that cycle:

```ruby
Apartment::PoolObserver.install!(
  sink: sink,
  sample_interval: 30,
  backend_count: -> { MyConnectionProxy.active_connections }
)
```

The callable is error-isolated: if it raises, the error is logged to `warn` and
the pass continues.

> **Fleet aggregation differs by gauge — don't SUM both blindly.**
> `tenant_pools_live` is **per-process** (each process reports its own
> `PoolManager`), so the fleet figure is a **SUM** across processes.
> `backend_connections` is per-process only if your `backend_count` returns a
> per-process number (e.g. `ActiveRecord::Base.connection_pool.connections.size`).
> A **cluster-wide** source — `pg_stat_activity`, an RDS Proxy / PgBouncer total —
> returns the *same* value from every process, so it must be rolled up with **MAX
> (or last), never SUM**, or a dashboard multiplies it by the process count. Match
> the dashboard aggregation to what your callable actually measures.

### Teardown

```ruby
$apartment_observer.stop!
```

`stop!` unsubscribes from all events and shuts down the gauge sampler. Safe to
call twice. Call it in a shutdown hook (e.g. `at_exit`, Puma's `on_worker_shutdown`)
to avoid orphaned subscriptions across worker restarts.

### Constructor reference

| Argument | Default | Meaning |
|---|---|---|
| `sink:` | required | Callable `(Sample) -> void`; receives every sample |
| `sample_interval:` | `nil` | Seconds between gauge passes; `nil` disables the sampler |
| `backend_count:` | `nil` | Callable `-> Numeric|nil`; drives `:backend_connections` gauge |
