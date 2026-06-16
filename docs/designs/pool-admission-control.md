# Pool Admission Control (enforcing max_total_connections at create time)

## TLDR

`max_total_connections` was background GC, not an enforced bound: `PoolManager#fetch_or_create`
always registered a new pool, and the cap was enforced only later by the
`PoolReaper`, which skips in-use/pinned pools. A create-heavy fan-out could exceed
`max_total × pool_size` indefinitely. Fix: **synchronous admission control** — when a
new pool would breach the cap, `fetch_or_create` evicts the LRU *idle* pool inline
before establishing the new one. When no pool can be evicted (all pinned/in-use), a
`pool_overflow_policy` decides: **`:evict_idle`** (default, soft cap — allow the pool,
emit `:cap_unmet`) or **`:raise`** (`PoolCapacityReached`, hard fail). The reaper keeps
running as the steady-state trimmer.

## Problem

`PoolManager#fetch_or_create` uses `Concurrent::Map#compute_if_absent`: a new tenant
key always creates and registers a pool. Nothing checks `max_total` on that path. The
ceiling lives in `PoolReaper#evict_lru`, which runs on a timer and **skips protected
pools** (pinned by fixtures, or with a leased connection / open transaction).

So with a burst of distinct tenants — or pools held in-use faster than the reaper
evicts — pool count grows past `max_total` and stays there until enough pools go idle.
For a large schema-per-tenant adopter this means total backend connections
(`pool count × tenant_pool_size`) can blow past the budget a PgBouncer / RDS Proxy or
the database itself is sized for. The cap that was supposed to protect that budget does
nothing on the hot path.

## Design

### Admission seam in `fetch_or_create`

When a cap is configured, `PoolManager` routes cold creates through a serialized
admission path:

1. **Hot path unchanged.** An existing pool returns lock-free (a `Concurrent::Map`
   read + timestamp touch). No cap logic on reuse.
2. **Cold path serialized.** Under a per-manager `@create_mutex`, double-check the key,
   then call `admission_controller.admit!(tenant_key)`, then establish + register the
   pool. The capacity check, the eviction, and the insert are atomic with respect to
   other creators, so the count is a true upper bound: only the create path adds pools,
   and it never adds while at capacity (except the documented soft-overflow case).

`admit!` is the `PoolReaper` itself — it already owns eviction policy, the
pinned/in-use protection predicates, and AR-handler deregistration. Reusing it keeps a
single eviction implementation (`evict_tenant`) for both the timer and admission paths.
`PoolManager` stays a cache; the reaper stays the eviction authority; the manager asks
the authority to make room.

```
admit!(incoming):
  return unless max_total
  while pool_count >= max_total:
    break unless evict_one_idle_evictable(exclude: incoming)   # LRU, skip pinned/in-use/default
  return if pool_count < max_total
  apply_overflow_policy(incoming)
```

`admit!` drains to strictly below the cap (so the incoming pool lands at exactly
`max_total`), absorbing any prior soft-overflow at the same time.

### Overflow policy (the no-idle-pool case)

When every other pool is pinned or in-use, eviction can't free a slot. The policy
decides what happens then. Eviction of an idle pool when one *is* available is **not**
policy-dependent — it always happens; the policy only governs saturation.

| Policy | At capacity, an idle pool exists | At capacity, all pinned/in-use |
|---|---|---|
| `:evict_idle` (default) | Evict LRU idle, admit new | **Soft cap** — admit anyway, emit `:cap_unmet` |
| `:raise` | Evict LRU idle, admit new | **Hard fail** — raise `PoolCapacityReached` |

### Recommendation — default `:evict_idle`

**Prioritize request availability; make the hard ceiling opt-in.** `:evict_idle` never
blocks or fails a request: it bounds steady-state growth (every admission evicts before
it adds) and only exceeds the cap transiently when *every* pool is genuinely busy — a
self-correcting condition the reaper trims as soon as work finishes. This matches the
existing reaper, which already emits `:cap_unmet` rather than killing in-use pools.

Adopters who must not exceed a backend connection budget under any condition (a fixed
PgBouncer ceiling) opt into `:raise` and shed load at the edge. The cost of `:raise` is
that a saturation spike surfaces as request errors instead of a transient overshoot.

### Request-path latency trade-off

Serializing cold creates under `@create_mutex` means concurrent first-touches of
*different* tenants run one at a time. The whole create block is held under the lock —
not just `establish_connection`, but the pending-migration check and any per-tenant
schema-cache file load that follow it in `ConnectionHandling`. This is deliberate: a hard
count bound requires serializing the check-and-add. It applies only when
`max_total_connections` is set (opt-in), only to cold creates (once per tenant per
worker), never to the hot reuse path. The alternative — a lock-free check — can't bound
the count because two creators can both observe headroom and both add. The widest case is
a deploy cold-start burst, where many workers cold-create concurrently; size
`max_total_connections` and the worker count with that window in mind.

Blast radius of `:raise`: `PoolCapacityReached` propagates out of the create path, so it
surfaces as a 500 in a web request or a failed job — intentional load-shedding, not a
silent drop. `:evict_idle` (default) never fails a request.

## Alternatives considered

- **Enforce in the reaper only (status quo).** Eventually-consistent; cannot bound a
  burst. This is the bug.
- **Admission in `ConnectionHandling` before `fetch_or_create`.** The size-check and the
  create aren't atomic across request threads, so the count can overshoot by the number
  of concurrent cold creates. Rejected for a non-atomic bound.
- **`:block` policy (wait for a pool to free, then evict).** Considered and **deferred.**
  It needs a wait-timeout config and condition-variable signaling, holds `@create_mutex`
  while parked (stalling all other cold creates), and buys little over the two shipped
  policies: `:evict_idle` already prevents unbounded growth, and `:raise` already gives a
  hard ceiling with simpler, more predictable failure semantics than a bounded wait that
  ends in a raise anyway. No adopter has asked for blocking back-pressure. Adding it later
  is localized: a third `when` in `apply_overflow_policy` plus a timeout config. Revisit
  if an adopter needs to throttle (not fail) at saturation.
- **Evict a single pool per admission (no drain loop).** Keeps net growth flat but never
  recovers from a prior overshoot inline. The drain loop converges without waiting for the
  reaper, at negligible cost (pool count is small).

## Configuration

- `pool_overflow_policy` — `:evict_idle` (default) or `:raise`. Only meaningful with
  `max_total_connections` set.

## Scope / out of scope

- In scope: synchronous admission, the two policies, reuse of the reaper's eviction.
- Out of scope: `:block` (deferred, above); the libpq `options` search_path change
  (issue #438); per-tenant pool sizing (issue A, shipped separately).

## Known limitations & shared races

- **`:evict_idle` is a tight soft cap, not a hard ceiling.** It bounds steady-state
  growth (every admission evicts before it adds) but, when *every* pool is pinned or
  in use, it admits the new pool and emits `:cap_unmet` rather than blocking or
  failing. The count can therefore transiently exceed `max_total` under genuine
  saturation. Adopters who need a hard ceiling (a fixed PgBouncer / RDS Proxy budget)
  must set `pool_overflow_policy: :raise`.
- **Eviction is best-effort (TOCTOU).** `admit!` reuses the reaper's `protected_pool?`
  → `evict_tenant` sequence, which checks pinned/in-use then removes as separate steps.
  A pool can become in-use in the sub-millisecond window between. This is the same
  race the background reaper already has (see `docs/testing.md`, "Pool lifecycle in
  tests") — admission adds a request-thread trigger but no new race class. Cost of an
  unlucky race is an in-flight query error on that pool, not cross-tenant data loss
  (pool config is tenant-specific; disconnect fails closed).
- **Do not resolve tenant pools from eviction hooks or admission-time subscribers.**
  `@create_mutex` is non-reentrant; a custom `on_evict` callback or `:evict`/`:cap_unmet`
  subscriber that calls `ActiveRecord::Base.connection_pool` for an uncached tenant on
  the creating thread would self-deadlock. The shipped paths don't do this.
- **Cap accounting trusts `PoolManager`'s count.** A pool that AR registers but
  `PoolManager` never stores (a post-`establish_connection` failure in
  `ConnectionHandling`) would undercount toward the cap. `ConnectionHandling`
  deregisters the shard on such failures so the count stays honest.

## Testing

- `admit!` at capacity evicts the LRU idle pool; below capacity and unconfigured-cap are
  no-ops.
- All-in-use saturation: `:evict_idle` allows overflow + emits `:cap_unmet`; `:raise`
  raises `PoolCapacityReached`.
- `fetch_or_create` calls `admit!` on cold create only (not on warm reuse); the count
  stays `<= max_total` across a create fan-out with idle pools, without running the
  reaper.
- No regression to the reaper timer path (idle + LRU eviction specs unchanged).
