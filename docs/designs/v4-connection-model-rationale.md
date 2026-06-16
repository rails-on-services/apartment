# Why v4 Uses Pool-per-Tenant (Connection Model Rationale)

## TLDR

v4 moves tenant isolation **out of** a mutable per-connection session variable
(`search_path`, flipped on a shared pool) **and into** the connection pool itself: one
immutable pool per `"tenant:role"`, each with its tenant's `search_path` baked in at
connection establishment. This trades a higher backend-connection ceiling for isolation
by construction, safe cross-tenant concurrency, and the removal of the per-request `SET`
churn that pinned connection poolers under v3. Fully-qualified table names — the question
adopters keep raising (#200, #302, #438) — is the cleanest model on paper and is **not**
rejected as wrong; it is rejected as the gem's default because it makes tenancy an
every-query, app-wide concern instead of something the library can own at one boundary.

This is the "why we chose this" companion to the "what / how" docs. For the architecture
itself see [`apartment-v4.md`](apartment-v4.md); for the connection-budget controls see
[`pool-admission-control.md`](pool-admission-control.md) and
[`v4-pool-adopter-ergonomics.md`](v4-pool-adopter-ergonomics.md). This doc does not restate
those — it explains the decision behind them.

## The decision

In v3, every tenant shares one connection pool and tenant identity lives in a connection
session variable: each `Tenant.switch` issues `SET search_path` on the connection it
borrows. The connection is general-purpose; what makes it "tenant A's connection" is a
GUC that the next switch will overwrite.

v4 inverts that. Tenant identity becomes a property of the pool, not a mutation on a
borrowed connection. `Apartment::Patches::ConnectionHandling#connection_pool` keys a
distinct pool per `"#{tenant}:#{role}"`
(`lib/apartment/patches/connection_handling.rb`), and the PostgreSQL schema adapter bakes
the tenant's `schema_search_path` into that pool's immutable config at establishment time
(`PostgresqlSchemaAdapter#resolve_connection_config`,
`lib/apartment/adapters/postgresql_schema_adapter.rb`). There is no per-switch and no
per-query `SET`: switching tenants is a pool lookup, and the connection a query borrows
already has the right `search_path` because no other tenant ever borrows from that pool.

## v3's two structural limits this addresses

**1. Isolation depends on vigilance over a shared, mutable, connection-global
`search_path`.** Because the `search_path` is global to the connection and any code can
change it, a missed reset, an exception that skips cleanup, or a stray `SET` leaves the
connection pointing at the wrong tenant. The failure mode is the dangerous one: a
wrong-`search_path` query against a *live* schema returns the wrong tenant's rows with
**no error** — it is indistinguishable from a correct query until someone notices the
data is wrong. Low probability, high impact, silent. v3 mitigates this with disciplined
block-scoped switching and `ensure` cleanup, but the safety is procedural, not
structural.

**2. A shared connection with a mutable `search_path` cannot safely serve concurrent
cross-tenant work.** The `search_path` is connection-global state; two fibers (or an
async query and its caller) sharing a connection cannot each hold a different tenant
context, because the second `SET` races the first. v3's thread-local switching model is
the root of the cross-thread leakage reported in ActionCable, async query, and
fiber-server contexts (#199, #239, #304 — see [`apartment-v4.md`](apartment-v4.md)
§ Problems with v3). You cannot make a single mutable global concurrent by being careful;
the data structure has to change.

## What v4 buys, in priority order

**1. Tenant isolation by construction.** The `search_path` cannot be flipped under a
running query, because it is fixed for the life of the pool and the pool serves exactly
one tenant. The wrong-tenant-rows-with-no-error failure mode above is removed at the
mechanism level, not guarded against at the call site. (This bounds the *gem-induced*
leak, not application-level wrong-tenant selection — see Non-goals.)

**2. Safe cross-tenant concurrency.** Distinct tenants resolve to distinct pools, so
concurrent fibers, an async query and its consumer, or a streaming response and its
parent can each operate in their own tenant context without racing a shared global.
Tenant context rides on `ActiveSupport::CurrentAttributes` (fiber-safe), and the pool a
query lands on is determined by that context at resolution time. (The consumer-fiber
contract for `load_async` is its own subtlety — see
[`apartment-v4.md`](apartment-v4.md) § Async query correctness.)

**3. The per-request `SET` churn that blocked connection poolers is gone — with a
caveat.** v3 issues `SET search_path` on every switch, i.e. on essentially every request,
which drove near-1:1 connection pinning under PgBouncer / RDS Proxy transaction mode
(#302): a connection that has run a session `SET` cannot be multiplexed. v4 issues no
per-switch `SET` at all. **Honest qualification:** Rails' PostgreSQL adapter still runs a
**one-time** `SET search_path` when it *establishes* each new connection (it applies the
pool's baked-in `schema_search_path` once). So v4 does **not** magically unlock
transaction-mode multiplexing — a freshly established connection has still run a session
`SET`. That is exactly what issue #438 (set `search_path` via the libpq `options`
connection parameter, at the protocol level, avoiding the `SET` statement entirely) is
still open to close. What v4 *does* realize today is that eliminating per-request churn
makes a **connection ceiling and session-mode pooling viable** where v3's per-request
pinning made them impractical. Do not read this as "RDS Proxy compatible" without the
establishment-`SET` qualification.

## Alternatives considered, and why not chosen for the gem

These are legitimate models. The question is not "which is correct in the abstract" but
"which can a multi-tenancy *library* own at one boundary without conscripting every query
the application writes."

### v3 status quo — shared pool + per-switch `SET search_path`

The predecessor. Isolation by vigilance (procedural cleanup, not structural), no safe
cross-tenant concurrency, per-request `SET` that pins poolers. Sections above cover why
each of these is the limit v4 set out to remove. Rejected because the failures are
inherent to a shared mutable global, not to any fixable detail of the implementation.

### Fully-qualified table names — `"schema"."table"` everywhere, no `search_path`

The purest model, and the strongest on the dimensions this doc cares about. With every
table reference schema-qualified, there is no `search_path`, hence no session state, hence
**no `SET` to pin a pooler and nothing to leak** — it is best-in-class for connection
multiplexing and stateless by construction. On paper it dominates.

It is not the gem's default for one reason: **scope of ownership.** Fully-qualifying
names would require ActiveRecord to schema-qualify, *per tenant and dynamically*, every
table, index, sequence, association join, and raw-SQL fragment the application emits — not
once, but on every query, for code the gem does not control. That turns tenancy from a
single connection-routing boundary the library can own into a pervasive, app-wide,
every-query concern. The leak surface moves from "did the gem route the connection
correctly" (one place) to "did every query — including every gem dependency's queries and
every hand-written SQL string — remember to qualify" (everywhere). A library cannot
enforce that contract; only the whole application can.

So FQN is rejected as a *gem default*, not as a bad idea. It remains a legitimate
architecture, and for an application that adopts it pervasively it is not mutually
exclusive with v4 in the long term — an app could qualify its own hot paths while the gem
routes connections. The gem simply cannot make every-query qualification its baseline.

### Prepend `SET search_path` to every statement (the "atomic switch")

A middle position: instead of `SET` per switch, run `SET LOCAL search_path` (or an
equivalent prefix) inside every statement so the window between switching and querying
shrinks to zero. This closes the *timing* class of the wrong-tenant leak — there is no
interval during which a query can run against a stale `search_path`. But it keeps tenancy
as **connection session state**, so it still pins poolers (a per-statement `SET` is more
churn, not less), and it requires intercepting every statement execution to inject the
prefix. It buys the smallest slice of the upside (one failure class) at meaningful cost,
and leaves the concurrency and pooler limits untouched. Rejected as solving the least
while complicating the most.

### The throughline

v4 localizes tenant isolation to the **connection-routing boundary** — the one seam a
multi-tenancy library can actually own — instead of spreading it across every query
(FQN), every statement (atomic prefix), or every developer's discipline (v3). The model
that owns the fewest places wins, provided those places are sufficient. Pool-per-tenant
is sufficient because the connection *is* the tenant.

## The trade-off v4 accepts

Pool-per-tenant raises the backend-connection ceiling: each `"tenant:role"` is a separate
pool, so total connection demand scales with **how many distinct tenants each process
touches**, not with how many threads it runs. A worker that handles a long tail of tenants
can hold far more pools than a v3 worker that shared one. This is the real cost, and it is
stated plainly because pretending otherwise is how adopters get surprised by their
database connection limit.

The gem ships the mechanisms to bound it (all cross-linked, not restated here):

- **`tenant_pool_size`** — cap connections per tenant pool; injected into each pool's
  config (`AbstractAdapter#apply_tenant_pool_size`). Defaults to `nil` (Rails' own
  default applies) for back-compat.
- **`max_total_connections` + synchronous admission control** — a hard-ish ceiling on
  total pools: a cold create at capacity evicts the LRU idle pool inline before
  establishing the new one, with `pool_overflow_policy` (`:evict_idle` soft cap /
  `:raise` hard cap) governing the all-busy case. See
  [`pool-admission-control.md`](pool-admission-control.md).
- **`PoolReaper`** — background idle + LRU eviction so cold tenants don't hold pools
  forever (`lib/apartment/pool_reaper.rb`); reap cadence is decoupled from the idle
  window via `reaper_interval`.
- **`Tenant.each(release_connection:)`** — release leased connections between tenants in a
  fan-out so finished tenants' pools become reap-eligible mid-run, instead of one warm
  connection per visited tenant. See
  [`v4-pool-adopter-ergonomics.md`](v4-pool-adopter-ergonomics.md) and the README
  "Iterating across tenants" section.

The honest framing: v4 chose a model whose default footprint is larger and gave adopters
the levers to bound it, rather than a model whose footprint is small but whose isolation
is procedural. The connection ceiling is a capacity-planning problem with knobs; the v3
silent-leak is not.

## Non-goals and honest caveats

- **v4 prevents the `search_path`-mutation leak, not application-level wrong-tenant
  selection.** If your code switches into the wrong tenant — asks for tenant B when it
  meant tenant A — v4 will faithfully route to B's pool and return B's data. The mechanism
  guarantees that a query runs against the tenant the code *asked for*; it cannot know
  which tenant the code *should have* asked for. Authorization and correct tenant
  resolution remain the application's job (see the elevator and
  [`elevator-tenant-validation.md`](elevator-tenant-validation.md) for the request-path
  guardrails the gem does provide).
- **The pooler benefit is "ceiling becomes viable," not "transaction-mode multiplexing
  unlocked."** The one-time establishment `SET` still exists (#438). Session-mode pooling
  and a fixed connection budget are the realized wins; do not overclaim transaction-mode
  compatibility.
- **FQN remains a reasonable alternative** for teams that want maximal pooler statelessness
  and are willing to own every-query qualification themselves. v4 does not foreclose it.
- **No runtime detection of consumer-fiber leaks.** The async-query contract is a
  documented discipline, not an enforced one — see
  [`apartment-v4.md`](apartment-v4.md) § Async query correctness.

## References

- **Issues** — #200, #302, #438: variants of "why not fully-qualify table names / avoid
  `search_path` entirely?" #302 is the PgBouncer / RDS Proxy session-pinning report that
  motivated removing per-request `SET`; #438 tracks the still-open libpq `options` path
  that would remove even the one-time establishment `SET`.
- **Architecture (what / how)** — [`apartment-v4.md`](apartment-v4.md): pool resolution,
  `CurrentAttributes`, async-query correctness, PgBouncer section, open-issue resolution
  table.
- **Connection-budget controls** — [`pool-admission-control.md`](pool-admission-control.md)
  (the ceiling), [`v4-pool-adopter-ergonomics.md`](v4-pool-adopter-ergonomics.md) (reaper
  control, iteration hygiene, observability).
- **Upgrade context** — [`../upgrading-to-v4.md`](../upgrading-to-v4.md) § What Changed and
  Why, § Connection Model.
