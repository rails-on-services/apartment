# v4 Pool Adopter Ergonomics

## TLDR

Four small additions that remove boilerplate large schema-per-tenant adopters
currently reinvent against the v4 pool-per-`"tenant:role"` model:

- **A — `config.reap_in_test`**: control the reaper's `Rails.env.test?` auto-stop
  declaratively, so adopters stop writing boot guards around it.
- **B — `Tenant.each(release_connection:)` + iteration guidance**: release the leased
  connection between tenants so pools stay reap-eligible during a fan-out, plus docs on
  choosing a cross-tenant primitive (a v4 `switch` creates a pool — even for pinned/global
  reads).
- **C — `Apartment::PoolObserver`**: a sink-agnostic subscriber (+ optional gauge sampler)
  for the gem's pool events. Ships no transport; the adopter's sink maps samples to its
  metrics backend.
- **D — `docs/observability.md`**: the event/stats contract the gem already emits but never
  documented.

Each ships as its own PR. Nothing AWS/Sidekiq/PostgreSQL-specific lands in the gem.

## Motivation

v4 keys a separate connection pool per `"tenant:role"`, so backend-connection demand scales
with tenant fan-out. The gem already gives adopters the primitives to manage and observe
that (the reaper, admission control, `PoolManager#stats`, instrumentation events). But three
patterns recur in adopter code because the gem stops one step short of turnkey:

1. **Boot guards around the reaper's silent test auto-stop.** `Railtie.deactivate_pool_reaper_in_test_env!`
   stops the reaper whenever `Rails.env.test?`. There is no config to override it — only the
   imperative `Apartment.pool_reaper.start`. Adopters whose environment model doesn't map
   cleanly to `RAILS_ENV` write a boot guard to keep a deployed process from silently
   disabling reaping.
2. **Per-iteration connection release, and "which iteration primitive?" confusion.**
   `Tenant.each` switches into each tenant; under v4 each switch leases a connection that
   stays checked out, so a long fan-out holds one un-reapable pool per visited tenant. Worse,
   `Tenant.each` gets reached for when no switch is needed at all — and a `switch` resolves
   pinned/global models *through the tenant pool* (shared-pinned-connections), so even reading
   global data inside a switch spins up a tenant pool.
3. **A from-scratch telemetry module.** The gem emits the right events but documents no
   observability contract and ships no subscriber, so each adopter re-derives the event names,
   payloads, and a sampler before they can watch pool pressure.

## Design

### A. `config.reap_in_test` — declarative reaper control

**Add a boolean config; the railtie reads it before stopping the reaper.**

- `config.reap_in_test` — Boolean, **default `false`** (today's behavior: reaper stopped under
  `Rails.env.test?`). Validated like the other booleans in `Config#validate!`.
- `Railtie.deactivate_pool_reaper_in_test_env!` gains one guard: `return if Apartment.config.reap_in_test`.
  When `true`, the reaper keeps running in test.
- **Adopter payoff**: set `reap_in_test = true` to keep eviction on regardless of what Rails
  reports as the environment — a misconfigured or non-standard deployment no longer silently
  leaks connections, so no boot guard is needed. The existing `:reaper_stopped` event still
  fires when the reaper *is* stopped.

Back-compat: default `false` reproduces the current `Rails.env.test?` stop exactly.

### B. `Tenant.each(release_connection:)` + iteration guidance

**Code.** `Tenant.each(tenants = nil, release_connection: false)`. When `release_connection` is
`true`, release the leased connection after each iteration so each finished tenant's pool
becomes reap-eligible mid-fan-out:

```ruby
def each(tenants = nil, release_connection: false)
  raise(ArgumentError, ...) unless block_given?

  tenants ||= Apartment.tenant_names
  tenants.each do |tenant|
    switch(tenant) { yield(tenant) }
    ActiveRecord::Base.connection_handler.clear_active_connections! if release_connection
  end
end
```

Default `false` preserves current behavior. The release is the broad
`clear_active_connections!` (handler-wide idle-lease release), not a per-pool release — proven
sufficient in adopter use and far simpler.

**Docs.** A "choosing a cross-tenant iteration primitive" section in `docs/observability.md`
(cross-referenced from the README tenant-operations section), framed on one question — *does the
block do per-tenant-schema work?*:

| Need | Use | v4 cost |
|---|---|---|
| Names only (enqueue, list) | `Apartment.tenant_names.each { ... }` | No switch, no pool created |
| Per-tenant-schema work | `Apartment::Tenant.each(release_connection: true) { ... }` | One pool per tenant; released between iterations |
| Global/pinned data only | Don't switch — read it in the default context | A switch would resolve pinned models through the tenant pool |

The third row is the non-obvious one: under shared-pinned-connections a `switch` routes pinned
and excluded models through the current tenant's pool, so switching only to read global data
spins up a tenant pool for nothing.

### C. `Apartment::PoolObserver` — sink-agnostic observability

**A small class that subscribes to the gem's notifications, normalizes each into a `Sample`, and
forwards to a caller-supplied sink. Ships no transport.**

```ruby
Apartment::PoolObserver.install!(
  sink: ->(sample) { Metrics.emit(sample.name, sample.value, sample.dimensions) },
  sample_interval: 30,                       # optional: starts a gauge sampler TimerTask
  backend_count: -> { current_backend_count } # optional: adopter's DB-specific ground truth
)
```

- **`Sample`** — `Data.define(:name, :kind, :value, :dimensions, :payload)`. `kind` is `:counter`
  (events) or `:gauge` (samples); `name` is a Symbol (`:evict`, `:tenant_pools_live`, …);
  `dimensions` is a curated Hash (e.g. `{ reason: :idle }`); `payload` is the raw notification
  payload so the sink can read anything the curated set omits.
- **Subscribes to** the pool-lifecycle events: `create`, `evict`, `cap_unmet`, `skip_evict`,
  `reaper_stopped`. Each becomes a `:counter` Sample with `value: 1`.
- **Optional sampler** — when `sample_interval` is given, a `Concurrent::TimerTask` (same idiom
  as the reaper) emits `:gauge` Samples from `PoolManager#stats` (`tenant_pools_live`) and, when
  `backend_count` is supplied, `backend_connections`. Without an interval, the observer only
  subscribes; the adopter can call `#sample!` from their own scheduler.
- **Error isolation** — every sink/sampler call is rescued and logged; the observer never raises
  into the gem's instrumentation or timer path.
- **Lifecycle** — `install!` returns the observer; `#stop!` unsubscribes and shuts the sampler.
  Like the reaper, after `fork` the adopter re-installs (web/worker boot hook).

The two adopter-owned seams — the **sink** (transport/metric naming) and **`backend_count`**
(DB-specific ground truth, e.g. a `pg_stat_activity` count) — are exactly the parts that must not
live in the gem. Alerting stays in the sink: it can branch on `sample.name` to page on
`:cap_unmet` / `:skip_evict`.

### D. `docs/observability.md`

The contract the gem already emits, written down once:

- **Event catalog** — all seven `*.apartment` events (`create`, `drop`, `evict`, `cap_unmet`,
  `skip_evict`, `reaper_stopped`, `migrate_tenant`): when each fires and its payload fields
  (e.g. `evict` → `tenant`, `reason`; `skip_evict` → `busy_connections`, `open_transactions`;
  `cap_unmet` → `max_total`, `current`, `unevicted`).
- **`PoolManager#stats`** — `total_pools`, `tenants`.
- **The `PoolObserver` recipe** (ships in PR 1). The iteration-primitive table from B is
  added in PR 3, alongside the `release_connection:` code it documents — so the doc never
  references an option the gem hasn't shipped yet.

## Alternatives considered

- **Tri-state `pool_reaper_enabled` (`:auto`/`true`/`false`)** instead of boolean `reap_in_test`.
  More flexible, more surface. Rejected: the only real friction is the test auto-stop; a boolean
  named for it is clearer.
- **Always release the connection in `Tenant.each`** (no opt-in). Rejected: a behavior change that
  could break callers relying on connection reuse across iterations.
- **Per-pool precise release** instead of `clear_active_connections!`. Rejected as
  over-engineering; the broad release is proven sufficient and reads plainly.
- **Ship a concrete sink** (CloudWatch/StatsD/Datadog). Rejected: couples the gem to a transport
  and its SDK. The sink callable keeps the gem dependency-free.
- **Snapshot-only observer** (no built-in sampler). Reasonable, but the optional `TimerTask`
  mirrors the reaper and saves every adopter the same scheduler wiring; kept as opt-in.

## Out of scope

- Concrete metric transports and DB-specific backend-count queries — adopter callables.
- App-level environment guards (e.g. `PLATFORM_ENV` boot checks) — stay app-side; `reap_in_test`
  removes their reason, not their environment model.
- Changing the reaper's *default* test behavior — default stays "stop in test."

## Testing

- **A** — railtie keeps/stops the reaper in test under each `reap_in_test` value; config
  validation rejects non-boolean; default reproduces current behavior.
- **B** — `Tenant.each(release_connection: true)` releases leases (integration: a visited
  tenant's pool is reap-eligible after the iteration); default leaves leases held; arity/return
  unchanged.
- **C** — `PoolObserver` forwards a normalized `Sample` to a fake sink for each subscribed event;
  the sampler emits gauge Samples; a raising sink does not propagate; `stop!` unsubscribes and
  halts the sampler.
- **D** — doc only.

## PR sequence

Lead with the observer — it's what an adopter's hand-rolled telemetry module most directly
replaces, and it's self-contained (subscribe + forward, no behavior change).

1. **`Apartment::PoolObserver` + `docs/observability.md`** (event catalog, `PoolManager#stats`,
   observer recipe) — C and the observability half of D.
2. **`config.reap_in_test` + railtie guard** — A.
3. **`Tenant.each(release_connection:)` + the iteration-primitive section** added to
   `docs/observability.md` — B and the iteration half of D. The table ships with the
   `release_connection:` code it documents.
