# Pool Connection Budget + Checkout-Pressure Observability

## TLDR

`max_total_connections` is misnamed: it bounds **pool count**, not connections. `admit!`
checks `stats[:total_pools] < @max_total` ([pool_reaper.rb](../../lib/apartment/pool_reaper.rb)),
so the real per-process ceiling is `pool_count × tenant_pool_size`. An adopter who set
`max_total_connections: 8` at `tenant_pool_size: 2` got a true ceiling of 16 connections, not 8.
A separate v4 property surfaced the same week: a same-tenant job fan-out concentrates on **one**
small tenant pool and starves it (checkout timeouts), where v3's shared pool absorbed it.

Three changes, none touching the tenant data path or isolation — this is capacity, ergonomics,
and honesty:

1. **Honest connection-budget knobs** — split the one lying knob into `max_tenant_pools`
   (pool-count cap) and `max_tenant_connections` (a true tenant-pool connection ceiling);
   deprecate `max_total_connections` as an alias of `max_tenant_pools`. The admission seam
   enforces `min(max_tenant_pools, floor(max_tenant_connections / tenant_pool_size))`.
2. **Sizing + ceiling docs** — the rule `tenant_pool_size ≥ peak same-tenant per-process
   concurrency`, the true ceiling formula, and the lazy-allocation clarification.
3. **Checkout-pressure observability** — extend the opt-in `PoolObserver` gauge sampler with
   `pools_waiting`, `pools_saturated`, and `max_checkout_waiting` so same-tenant starvation is a
   metric, not a multi-hour debug.

Validated by a five-model panel (Codex, Gemini, Cursor, Mistral, Bedrock/DeepSeek): unanimous on
the naming split, on `derive + min` as the minimal correct enforcement at a pool-count seam, and
on shipping gauges now while deferring an AR-checkout monkeypatch.

## Contents

- [Background](#background)
- [Item 1 — honest connection-budget knobs](#item-1--honest-connection-budget-knobs)
- [Item 2 — sizing and ceiling documentation](#item-2--sizing-and-ceiling-documentation)
- [Item 3 — checkout-pressure observability](#item-3--checkout-pressure-observability)
- [Testing](#testing)
- [Scope and non-goals](#scope-and-non-goals)
- [Alternatives considered](#alternatives-considered)

## Background

### The name lies once pool size exceeds 1

v4 is pool-per-tenant: each `tenant:role` key gets its own ActiveRecord connection pool sized to
`tenant_pool_size`, with `search_path` baked into the config. A background admission controller
(`PoolReaper`, wired when a cap is configured) bounds how many pools exist per process. That bound
is **pool count** — `admit!` and the timer LRU path both compare `stats[:total_pools]` against
`@max_total`. The knob feeding it is named `max_total_connections`. So the number an adopter reads
as a connection ceiling is actually a pool ceiling; the real connection ceiling is
`pool_count × tenant_pool_size` and is invisible in the config. See
[pool-admission-control.md](pool-admission-control.md) for the admission mechanism this builds on.

### Same-tenant fan-out starves one pool

A Sidekiq role (concurrency ~5) received a fan-out of dozens of jobs for a **single** tenant. Each
job leased a connection from that one tenant's pool. With `tenant_pool_size: 2`, three threads
blocked on checkout and hit the 5s `ConnectionTimeoutError`; the reaper's `skip_evict(in_use)`
fired because the pool was mid-transaction and could not be evicted. DB headroom stayed ample —
this was intra-pool checkout contention, not a connection-count problem. v3's shared thread-local
pool absorbed the same fan-out because every thread drew from one large shared pool; v4 partitions
per tenant, so a same-tenant burst concentrates on one small pool. This is the pool-per-tenant
model doing exactly what it says (isolation moves contention into the tenant's own pool), not a
regression — but the safe `tenant_pool_size` was undocumented and the default too small for a
fan-out workload.

The admission cap does **not** address this incident: `total_pools` was 1. Intra-pool starvation
is purely `tenant_pool_size` versus same-tenant process concurrency (Item 2). Items 1 and 3 make
the connection budget honest and the pressure visible; Item 2 states the rule that actually
prevents the starvation.

## Item 1 — honest connection-budget knobs

### Three keys

| Key | Meaning | Status |
|---|---|---|
| `max_tenant_pools` | Pool-count cap. Exactly today's `max_total_connections` behavior, renamed. | New |
| `max_tenant_connections` | True **tenant-pool** connection ceiling. The primary safety knob. | New |
| `max_total_connections` | Deprecated alias of `max_tenant_pools` (its current pool-count meaning). | Deprecated; removed in v5 |

The `tenant_` prefix is deliberate: the ceiling bounds only tenant-pool connections. The default
(primary) pool and an optional separate pinned pool are additional, small, and fixed — the name
says `tenant`, so excluding them is honest rather than a footnote.

### Derive + min

Admission enforces a single **effective pool budget**, the stricter of whichever knobs are set:

```
effective_pool_budget = [
  max_tenant_pools,                                   # if set
  (max_tenant_connections / tenant_pool_size).floor   # if max_tenant_connections set
].compact.min          # neither set → nil → uncapped (current lock-free fast path)
```

With a global `tenant_pool_size` (every tenant pool the same size), max tenant-pool connections
`≤ effective_pool_budget × tenant_pool_size ≤ max_tenant_connections`. Because the admission seam
only sees pool creation — never per-connection checkout — a derived pool budget is the only hard
connection ceiling enforceable there. `floor` is conservative on purpose: `ceil` would over-admit
past the connection budget.

### Derivation lives in `Apartment.configure`, not the reaper

`@max_total` feeds two reaper paths — `admit!` (synchronous admission) and the timer LRU eviction
(`evict_lru`, `excess = total - @max_total`). Rather than teach both about two knobs, compute
`effective_pool_budget` once at wiring time and pass the reaper a single number via its existing
`max_total:` constructor argument. Both paths then enforce the same derived bound automatically,
and `PoolReaper` stays agnostic about the knobs. Expose the computation as
`Config#effective_pool_budget` so it is unit-testable in isolation and `Apartment.configure` simply
reads it.

### Validation (`Config#validate!`)

- `max_tenant_pools` — positive integer or `nil` (mirrors the current `max_total_connections`
  check).
- `max_tenant_connections` — positive integer or `nil`.
- `max_tenant_connections` set but `tenant_pool_size` `nil` → `ConfigurationError`. Without a known
  per-pool size the pool budget cannot be derived (`tenant_pool_size: nil` means "inherit the base
  pool size," which is not knowable at config-validation time).
- `max_tenant_connections < tenant_pool_size` → `ConfigurationError`. Otherwise
  `floor(ceiling / size)` is 0 and the admission controller would reject every tenant pool
  permanently. Evaluate after `apply_defaults!` so any derived values are in place.
- `max_total_connections` **and** `max_tenant_pools` both explicitly set and unequal →
  `ConfigurationError`. They are the same concept under two names; an unequal double-spec is
  ambiguous, so fail loudly rather than silently pick one. The check reads the user-provided values
  and runs *after* the alias step (below), which only fills `max_tenant_pools` when it was unset —
  so a lone `max_total_connections` leaves the two equal and passes, while an explicit unequal pair
  still differs and raises.

### Deprecation and migration

When `max_total_connections` is set, emit a one-time deprecation warning naming its replacement,
and alias it to `max_tenant_pools` (its **current** pool-count meaning — no behavior change). An
existing `max_total_connections: 8` keeps meaning "8 pools." Normalize this during config load
(in the mutating `apply_defaults!` step, before the read-only `validate!`) so `max_tenant_pools`
is the single source of truth afterward. **Alias only when `max_tenant_pools` is unset** — never
overwrite an explicit value — so the both-set-unequal guard above can still fire on a genuine
double-spec. Removal is scheduled for v5, matching
the existing `excluded_models` deprecation pattern. The gem is pre-beta (alpha) with one test-only
adopter, so the migration cost is a warning and a rename; the clarity gain is permanent. This
deliberately avoids repurposing `max_total_connections` to mean connections — that would change an
existing key's production behavior under the same spelling (see
[Alternatives](#alternatives-considered)).

### Honesty scope and its limits (documented, not hidden)

- **`tenant:role` pools.** Pool keys are `tenant:role`, so a pool is per tenant-role. One tenant
  using `writing` + `reading` roles holds two pools. `max_tenant_pools` caps tenant-role pools;
  the ceiling formula multiplies accordingly. Docs must say "pools," not "tenants."
- **Soft cap under `:evict_idle`.** When every pool is pinned or in use, `admit!` admits anyway and
  emits `:cap_unmet` (the existing behavior). The connection ceiling is then also soft. Adopters
  who need a hard ceiling set `pool_overflow_policy: :raise`.
- **Excluded pools.** The default pool and any separate pinned pool sit outside the tenant ceiling.

## Item 2 — sizing and ceiling documentation

The sizing rule is the actual fix for the starvation incident and cannot be validated at config
time (peak concurrency is runtime-dependent), so it must be documented prominently.

### The sizing rule

> `tenant_pool_size ≥ peak same-tenant per-process concurrency` — the maximum number of threads or
> fibers in one process that can touch the **same** tenant pool at once. For a Sidekiq role that is
> its `concurrency`; for a fan-out of same-tenant jobs on one role, it is that role's concurrency.

Explain the v3→v4 shift: v3's shared pool spread a same-tenant burst across one large pool; v4
concentrates it on that tenant's own pool. Recommend the application-level mitigations too (job
batching / concurrency-limit middleware) — a same-tenant thundering herd is an application pattern,
not a framework bug — with sizing as the gem-level lever.

### The true ceiling formula

```
tenant_pool_connections ≤ effective_pool_budget × tenant_pool_size
total_process_connections ≈ (effective_pool_budget × tenant_pool_size) + default_pool + pinned_pool
where effective_pool_budget = min(max_tenant_pools, floor(max_tenant_connections / tenant_pool_size))
```

Include a worked example spanning both knobs and a multi-role tenant.

### Required notes

- **Lazy ceiling, not reservation.** `tenant_pool_size` is an upper bound; AR creates connections
  on demand and the reaper evicts idle pools. Sizing for peak does **not** hold that many
  connections open at steady state. This directly answers the adopter's likely fear that
  "`tenant_pool_size: 5` means five open connections forever."
- **Pessimism of the derived budget.** `floor(ceiling / size)` assumes every admitted pool is
  saturated. An oversized `tenant_pool_size` therefore reduces the number of concurrent tenants the
  budget allows — a real tradeoff to state.
- **`:raise` for hard budgets.** Adopters sizing an external pooler (PgBouncer / RDS Proxy) to
  `max_tenant_connections` should pair it with `pool_overflow_policy: :raise` if they cannot
  tolerate the soft-overflow transient.

### Documentation locations

`README` / config reference, `pool-admission-control.md` (the knob rename), `upgrading-to-v4.md`
(the deprecation), `lib/apartment/CLAUDE.md`, and `v4-connection-model-rationale.md`.

## Item 3 — checkout-pressure observability

Extend `PoolObserver#sample!`. Today it emits `tenant_pools_live` (and an optional adopter
`backend_connections`) on a `Concurrent::TimerTask`, forwarding `Sample`s to a caller sink. Add a
per-tenant-pool walk that reads each pool's AR `ConnectionPool#stat` and emits **low-cardinality
gauges**:

| Gauge | Kind | Value |
|---|---|---|
| `pools_waiting` | gauge | Count of tenant pools with `stat[:waiting] > 0` (threads blocked on checkout) |
| `pools_saturated` | gauge | Count of tenant pools with `busy >= size` |
| `max_checkout_waiting` | gauge | The single largest `waiting` across pools this tick |

`pools_waiting` is the direct starvation signal — it is exactly what was non-zero during the
incident (the writer pool had `waiting = 3`). The walk is O(pools), which is cheap because pool
count is bounded by the admission cap.

### Cardinality: tenant in payload, not a metric dimension

`max_checkout_waiting` carries the offending tenant, but in the `Sample#payload` (for log/debug
sinks), **not** as a metric dimension by default. A gauge whose dimension **value** churns every
tick — a different worst tenant each sample — produces unbounded time-series in CloudWatch/StatsD.
A tenant-labeled dimension is available as a documented, opt-in high-cardinality mode. The
aggregate gauges are dimensionless.

### Sampling is a pressure indicator, not a timeout counter

`stat[:waiting]` is **instantaneous**, not peak-held, so a short episode can fall between samples;
timer alignment means even a 5s interval can miss a 5s episode. The gauge reliably surfaces
**sustained** pressure (a fan-out lasting seconds) but is not lossless timeout accounting. Docs
recommend a short `sample_interval` (5–10s) on job/worker roles, keeping web at the default if
desired, and state this limitation plainly.

### Deferred: discrete checkout-timeout event

A lossless per-timeout event would require monkeypatching
`ActiveRecord::ConnectionAdapters::ConnectionPool#checkout` across Rails 7.2 / 8.0 / 8.1 / main,
where the pool internals and `stat` shape already vary. That maintenance cost is not justified by
current evidence, and standard APM already captures the resulting `ConnectionTimeoutError`. Revisit
only if an adopter needs lossless incident accounting that sampling cannot provide.

## Testing

- **Config / derivation:** `effective_pool_budget` returns the `min` over set knobs; `nil` when
  neither is set; `floor` rounding; the deprecation alias maps `max_total_connections` →
  `max_tenant_pools`; the one-time warning fires once.
- **Validation:** `max_tenant_connections` without `tenant_pool_size` raises; `max_tenant_connections
  < tenant_pool_size` raises; `max_total_connections` + `max_tenant_pools` unequal raises;
  positive-integer-or-nil checks on both new knobs.
- **Admission wiring:** with `max_tenant_connections` set, the reaper receives the derived budget;
  both `admit!` and the LRU path enforce it; the count stays `≤ effective_pool_budget` across a
  create fan-out with idle pools. Reuses the existing admission-control specs with the derived
  bound.
- **Observability:** `sample!` emits `pools_waiting` / `pools_saturated` / `max_checkout_waiting`
  with correct counts against constructed pool stats; the tenant appears in `payload`, not
  `dimensions`, by default; the sampler stays error-isolated (a raising `#stat` does not break the
  pass).

## Scope and non-goals

**Phasing** (settled in the implementation plan): likely (1) Item 1 knobs + validation + derivation
+ deprecation; (2) Item 2 docs — may share the Item 1 PR since the docs describe the knobs; (3)
Item 3 observability, separable.

**Non-goals:**

- **Live cross-pool connection counting.** Enforcing a connection ceiling by summing active
  connections at admission would need a different seam (per-checkout throttle) and severe lock
  contention. `derive + min` is the minimal correct transform given a fixed pool size.
- **`:block` overflow policy.** Already deferred in [pool-admission-control.md](pool-admission-control.md).
- **Per-tenant dynamic pool sizing / shared-overflow / hybrid shared-pool mode.** These fight the
  pool-per-tenant model (which exists for fiber safety, PgBouncer transaction-mode compatibility,
  and no thread-local tenant leakage). The incident is a consequence of that model, addressed by
  sizing and visibility — not by blurring tenant pools again.
- **W4 / libpq `options`.** Separate, docs-only (see the beta-readiness roadmap).

## Alternatives considered

- **(A) Repurpose `max_total_connections` to mean connections.** Rejected (panel: Codex p≈0.17,
  Cursor p≈0.12, all five preferred B). It changes an existing key's production behavior under the
  same spelling — the most dangerous form of the very ambiguity this work removes. Example:
  `max_total_connections: 20` at `tenant_pool_size: 5` silently drops from 20 pools to 4 on upgrade,
  causing eviction thrash. Alpha status encodes the ambiguity rather than removing it.
- **Independent runtime caps (pool count AND live connection count).** Rejected — needs live
  connection accounting under the admission lock; with a global `tenant_pool_size` it collapses to
  `derive + min` anyway.
- **Discrete checkout-timeout event now.** Deferred (see Item 3) — AR-version-fragile monkeypatch
  not justified by current evidence.
- **Longer literal name `max_tenant_connection_pools`.** Considered (Codex) for precision about
  `tenant:role` pools; rejected in favor of `max_tenant_pools` plus a docs note, for brevity.
