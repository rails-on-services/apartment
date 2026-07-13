# v4 Beta Readiness

Status: living. Defines what "beta" means for `ros-apartment` v4 and the scoped, prioritized workstreams that gate it. Created from the 2026-06-28 alpha→beta framing conversation; current version `4.0.0.alpha5`.

## Progress (updated 2026-06-29)

- **W5 — Cursor debt** ✅ shipped (#453): physical-name validation seam + advisory-lock ivar guard. Plus a review-driven follow-up (#454): validate pool-key-unsafe tenant names before admission/eviction.
- **W2 — Member 8** ✅ reactive half shipped (#455): the brainstorm collapsed this from the "design-first long pole" to a minimal `Apartment::Tenant.reload_schema_cache!` helper + a fix for the latent `schema_cache_per_tenant` load path. v4's pool-per-tenant already isolates schema caches and AR self-heals prepared statements, so the residual was only the shared/pinned-table amplifier. Design: `docs/designs/v4-schema-cache-recovery.md`.
- **W4 — PgBouncer libpq** ❌ **closed, not built (2026-07-12)**: the spike refuted the premise. `options` is dominated by a PgBouncer setting; correctness is governed by a **PG 18 floor**; the failure mode is a **silent cross-tenant read**, now shipped as a warning; and **RDS Proxy is not supported** (Rails pins it regardless of Apartment). W4 collapses to docs + a CI job. See [`w4-pgbouncer-libpq-spike.md`](w4-pgbouncer-libpq-spike.md).
- **Adopter answered the three open questions (2026-07-12)** — see W1/W3/W6 below. Net: **W1 is confirmed real and is now the only internal *code* work left; W3 collapsed to docs + a helper; W6 is in progress on a current gem (adopter is on alpha8), bounded by the rollout itself rather than by evidence.**
- **Remaining beta-blocking**: W1 (member 7 — build it), W3 (member 9 — contract + helper, no gem fix), W6 (adopter `:reading` rollout), then Track C packaging.
- **Critical path now**: **W1 is the only internal code item.** The beta date is still bounded below by W6, which is externally paced; W1/W3 fit inside that window.

## TLDR

**Beta = pragmatic posture on a correctness-complete floor.** We tell a new adopter "run v4 in staging" (documented-stable API with named escape hatches; *not* a GA-binding API freeze), but only once every *suspected* failure class is tested, the advertised PgBouncer/RDS-Proxy compatibility is **stated honestly** (see below — the spike replaced "implement it" with "document what is and is not safe"), and the primary adopter has exercised the real `:reading`-separated path. The posture is light; the floor is heavy. Almost all v4 engineering already shipped across alpha1–5 — beta is a correctness-closure + decision + documentation milestone, with **no remaining internal code long pole** (the PgBouncer libpq path was closed unbuilt by the W4 spike) and one external dependency (the adopter's rollout timeline). (Member 8, originally scoped as a second long pole, shipped in #455 as a minimal recovery helper once the brainstorm found v4 already isolates schema caches per pool — see Progress.)

## What beta means here (the decision)

A multi-tenancy gem the maintainer's own product runs in production can't ship a beta that "mostly works." Two independent axes, decided separately:

- **API-stability posture: pragmatic.** Beta does *not* freeze the public API to GA. We publish a soft deprecation promise and reserve named escape hatches. Rationale: v4 is a clean break already; over-committing to API permanence before real-adopter feedback is premature, and the pragmatic signal ("try it in staging") is the honest one.
- **Correctness floor: complete.** No *untested* suspected failure class ships in beta. The PgBouncer/RDS-Proxy compatibility v4 advertised as a goal is stated **honestly**: PgBouncer transaction mode is supported on PG 18+ with `track_extra_parameters`, is *unsafe* below that, and RDS Proxy is not a pooling solution for Rails at all. (The spike found the advertised goal was partly unreachable; saying so is the correctness-complete answer, not implementing a fix that does not work.) The primary adopter has run the path that exercises the gem's hardest seam (`:reading` on a distinct pool). Rationale: correctness gaps in tenant isolation are silent and catastrophic; "beta" must not paper over known-suspected ones.

This split is the whole design: **loose on promises, strict on behavior.**

## The four gates

1. **API surface + deprecation policy.** Public API (`Apartment::Tenant.*`, `Apartment.configure` keys, elevator classes, `Apartment::Model`/`pin_tenant`, notification event names, error hierarchy) is documented as the beta surface, with a one-paragraph soft deprecation policy. Lock the pool-knob config names that moved during the alphas (`tenant_pool_size` default 5→nil, `pool_overflow_policy`, `reap_in_test`, `reaper_interval`). No new written stability statement exists today — this gate creates it.

2. **Docs + upgrade-guide completeness.** README, `upgrading-to-v4.md`, and per-feature docs (adapters, elevators, caching, observability, testing) exist and cover alpha5 config. Beta adds a getting-started→production checklist and makes the async-query consumer-fiber contract prominent. The PgBouncer/RDS-Proxy story shipped as [`../connection-poolers.md`](../connection-poolers.md) — a supported-configuration matrix and a silent-cross-tenant-read warning, which is what the spike showed the honest state to be.

3. **Known-gap triage — every gap gets a verdict.** Failure-class members 7/8/9/10, the (now-closed) Cursor PR-review backlog, and the libpq path. Disposition below. Decision: **7 and 9 are tested before beta** (not documented-and-deferred); **8 was reclassified and mitigated** — the brainstorm found v4 already isolates schema caches per pool, so #455 shipped a minimal recovery helper + load-path fix rather than a failure-class integration test; 10 ships a cheap test-env workaround with the apartment-side fix deferred to adopter-reported need; **the libpq path is closed unbuilt** (W4 spike: dominated on PgBouncer, pointless on RDS Proxy). The Cursor backlog closed with W5 (#453/#454).

4. **Real-adopter green at depth.** The primary adopter's v4 migration is CI-green on the `:reading`-separated rollout path — the phase that puts a tenant's `:reading` role on its own pool and thereby exercises member 10 for real. Green at the earlier (Phase 0/1) rollout is *not* sufficient for beta. This gate is externally paced.

## Resolved decisions

| Question | Decision | Consequence |
|----------|----------|-------------|
| Beta posture | Pragmatic (try-in-staging) | Soft deprecation policy, not a GA-binding freeze (W8) |
| Adopter-green depth | Wait for `:reading`-separated rollout | Beta date bounded below by the adopter's rollout timeline (W6); surfaces member 10 for real |
| Members 7 & 9 | Test before beta | W1/W3 are beta-blocking, not deferred (member 8 split out — see below) |
| PgBouncer libpq path | ❌ **Closed — not built** (spike refuted it) | Dominated by a PgBouncer setting; PG 18 floor is the real constraint |
| RDS Proxy | ❌ **Not supported** as a pooling solution | Rails pins it regardless of Apartment ([rails/rails#40207](https://github.com/rails/rails/issues/40207) + 3 unconditional `SET`s) |
| PgBouncer CI | Free via service container | Public-repo runners are free; add a `pgbouncer` service to `ci.yml` — no spend, just config |
| Member 8 design depth | Resolved (#455) — minimal helper, not full invalidation | Brainstorm showed v4 already isolates schema caches per pool; shipped a manual recovery helper + load-path fix |
| Member 10 | Cheap test-env guard now (force read→`:writing` in test) | Apartment-side fix built only on adopter-reported replica-read-test need |
| Member 7 (W1) | ✅ **Confirmed real — build the gem-side recovery** | Adopter's `PQTRANS_INERROR` `ROLLBACK` loop is **v4-era and test-only**; they already concluded the fix is ours. Not a v3 ghost. |
| Member 9 (W3) | ✅ **Contract + helper; no gem fix** | Adopter audit found **none** of the risky threading patterns. Shape the helper around the hand-rolled pool eviction they *do* run, not a hypothetical bug. |
| W6 replication lag | ❌ **Not a beta gate** | The adopter's test replica shares the primary's database, so the lane proves **pool separation** — which is the gem seam. Lag is an app concern. |
| W6 completion bar | Rollout reaching production, not the gem version | The adopter's v4 bundle is already on **alpha8** (current). The lane validates a current gem; what remains is the rollout itself. |

## Scoped workstreams

Three tracks. Size is relative (S/M/L). Long poles flagged.

### Track A — Correctness (beta-blocking)

- **W1 — Member 7, `PQTRANS_INERROR` taint** (M) — ✅ **CONFIRMED REAL; BUILD IT. Now the only internal code work before beta.** Instrumented detection + recovery in `Apartment::Tenant.switch`'s ensure block, plus an integration spec.

  Adopter confirmation (2026-07-12) closed the open question of whether this was a v3 ghost. It is not: the adopter's defensive `ROLLBACK` loop checks `raw_connection.transaction_status == PG::Connection::PQTRANS_INERROR` and issues a `ROLLBACK` on every writing-pool connection after each cross-tenant example — and `git log -S` dates it to their **v4 migration**, not a v3 leftover. It is **test-only**: no production code path wraps `Tenant.switch`/`switch!` with it (their elevator rescues only connection-failure errors, not failed-transaction state). Their own analysis of a failed attempt to widen the predicate concluded the fix belongs in the gem rather than in app-side `ROLLBACK` hooks.

  So the shape is settled: a *test-only* workaround, in the adopter's v4 lane, that they have already diagnosed as ours. Build the recovery path; the workaround is what it should delete. See `fixture-pool-lifecycle.md` member 7.
- **W2 — Member 8, schema-cache / prepared-statement drift after tenant DDL** ✅ **shipped (#455)**. The brainstorm showed v4's pool-per-tenant already isolates schema caches per pool and AR self-heals prepared statements, collapsing the original long-pole scope. Shipped: the manual `Apartment::Tenant.reload_schema_cache!` recovery helper for the pinned/shared-table-DDL amplifier, plus a fix for the latent `schema_cache_per_tenant` load path. Design: `docs/designs/v4-schema-cache-recovery.md`.
- **W3 — Member 9, within-process thread/job boundaries** (S, was M) — ✅ **SCOPE COLLAPSED: documented contract + a small helper. No gem-level fix needed.** The suspicion was that Sidekiq-inline, async executors, `parallel_tests` workers, or app threads that `switch` inside a worker thread resolve pools differently from the originating thread.

  Adopter audit (2026-07-12) came back **clean, and it is a real signal rather than an absence of looking**: Sidekiq runs faked in specs (the two inline opt-ins execute synchronously on the example's own thread, so there is no cross-thread exposure); there is no `parallel_tests` — CI shards across *OS processes*, so per-tenant pool keying never crosses a thread boundary; and there are **zero** occurrences of `Tenant.switch`/`switch!` inside `Thread.new`, `Concurrent::Future`, or similar. Their one async executor never touches ActiveRecord.

  **The useful find is an API signal, not a bug.** Their single pool-aware call site hand-rolls the workaround — manually evicting the stale per-tenant pool (`Apartment.pool_manager&.remove_tenant`) before switching, on the main thread. That hand-rolled eviction is precisely what the helper should absorb. Design the contract + helper around *that*, not around a hypothetical threading bug.
- **W4 — PgBouncer libpq `options` (approach 1)** — ❌ **CLOSED, NOT BUILT (2026-07-12).** No longer a long pole; no longer a code workstream. The `ruby-pg`/PG-16/18 spike this workstream called for was run and it refuted the premise ([`w4-pgbouncer-libpq-spike.md`](w4-pgbouncer-libpq-spike.md)):
  - **libpq `options` is dominated.** PgBouncer **rejects** the `options` startup packet unless `search_path` is in `track_extra_parameters` — and once it is, v4's existing `SET`-based path is already safe *and* genuinely multiplexed. The approach buys nothing.
  - **What actually governs correctness** is PostgreSQL's version. `search_path` was not reported to clients before **PG 18** (so the "requires Citus 12+" note above is obsolete — vanilla PG 18 reports it), and on **PG ≤ 17 transaction mode cannot be made safe at all**.
  - **The failure mode was misdiagnosed**: not pinning but a **silent cross-tenant read**. Shipped as a user-facing warning ([`../connection-poolers.md`](../connection-poolers.md)).
  - **RDS Proxy — the one thing that could have justified the code — is closed too.** Rails pins on RDS Proxy for three reasons unrelated to tenancy (three unconditional `SET`s; the extended query protocol even at `prepared_statements: false`, [rails/rails#40207](https://github.com/rails/rails/issues/40207) closed-stale; `nextval`/advisory locks). Fixing Apartment's `search_path` would change nothing. **Decision: RDS Proxy is not supported as a pooling solution.**

  **What remains of W4** (small, Track C-ish): a supported-configuration statement and a PgBouncer CI service-container job asserting both directions — safe config isolates, unsafe config leaks — so we learn if PgBouncer or PostgreSQL ever changes this underneath us.
- **W5 — Cursor debt: advisory-lock fragility + raw-tenant validation** ✅ **shipped (#453, follow-up #454)**. Added a `physical_tenant_name` validation seam (pool-resolution validates the identifier the connection actually targets) and guarded the `@advisory_locks_enabled` ivar poke with a rename-detecting contract test. Follow-up #454 moved pool-key-unsafe-name rejection ahead of admission/eviction.

### Track B — Adopter validation (external-gated long pole)

- **W6 — Adopter `:reading`-separated rollout green** (—) — 🟡 **IN PROGRESS; the adopter's v4 CI lane is the agreed evidence.** Confirmed 2026-07-12: their main spec suite runs the v4 bundle against PostgreSQL 18 (the v3 bundle is kept only as a narrow regression lane), `ApplicationRecord` declares a `reading` role on a distinct database config, and read routing is opt-in through a concern with **no test-env escape hatch** — so reads genuinely cross into a separate `tenant:reading` pool. Their rollout doc states the position plainly: reading role yes, opt-in, read-touched tenants get a second pool.

  **The gem is current.** The adopter's v4 bundle pins **`4.0.0.alpha8`** — the latest release, carrying the `sequence_name` cross-tenant fix (#468), the connection-budget knobs (#466), and the checkout gauges (#467). So the green lane validates a current gem, not a stale snapshot. (An earlier draft of this section claimed the lock was ~53 commits behind; that was measured against the adopter's *v3 production* branch, whose v4 lockfile is naturally stale, rather than the branch the v4 work lives on. Corrected.)

  **One caveat, and it does not block us:** the test `replica` config points at the **same database** as primary (flagged `replica: true`), so the lane exercises **pool separation** but not replication lag. That is fine — **pool separation IS the gem seam** (member 10 is cross-role read visibility under fixtures). Replication lag is an application concern the gem has no stake in. Do not hold beta for it.

  **What remains is the rollout itself**, not the evidence: the adopter describes the `:reading` rollout as in-progress (adopted for test; production still ahead). Externally paced. With member 8 and W4 closed, this is the binding constraint on the beta date.
- **W7 — Member 10 disposition** (S now / L if-fix). Ship the cheap test-env guard (force `read_only_query`→`:writing` under `Rails.env.test?`; no gem change) as the supported answer now. Build the apartment-side fix (connection-share tenant `:reading` pools under fixtures) *only* if the adopter reports a need for replica-read test fidelity — historically rare. Resolves when W6 surfaces the behavior for real.

### Track C — Beta packaging (finalize last)

- **W8 — API-freeze decision + deprecation-policy paragraph** (S). Pragmatic-posture wording; lock the pool-knob config names. Finalize after W1/W3 settle the surface (W2/W4/W5 already settled).
- **W9 — Docs completeness** (M). Production checklist; prominent async consumer-fiber contract. The PgBouncer/RDS-Proxy docs already shipped ([`../connection-poolers.md`](../connection-poolers.md)); what remains is the PgBouncer CI job asserting the safe config isolates and the unsafe one leaks.
- **W10 — Open-issue enumeration + triage sweep** (S). Confirm the public tracker has nothing beta-blocking open before declaring triage clean. (`gh issue list` returned empty in the framing check — re-verify.)

## Critical path & sequencing

With W5 and W2 (member 8) shipped, **W4 (PgBouncer libpq) is the remaining internal long pole** — start it with a `ruby-pg` driver-support spike. W6 (adopter `:reading` rollout) runs the whole window, externally paced. W1 (member 7) and W3 (member 9) are independent and parallelizable. Track C closes last, once W1/W3/W4 lock behavior.

**Beta date is now bounded below by the adopter `:reading`-separated rollout green (W6)**, with W4 the longest internal pole. Everything else fits inside that envelope.

Suggested order of remaining plans: **W4** (longest internal pole, CI-unblocked via a free PgBouncer service container), then **W1 / W3** (members 7 and 9, parallelizable), then **Track C** packaging (W8–W10). W6 proceeds in parallel on the adopter's timeline.

## Cross-references

- `docs/designs/apartment-v4.md` — v4 architecture; PgBouncer approach-1 (still unimplemented), async-query correctness contract, notification events, error hierarchy.
- `docs/designs/fixture-pool-lifecycle.md` — failure-class members 7/9/10 (suspected), member 8 (reactive recovery shipped, #455), and the closed members 1–5.
- `docs/designs/v4-schema-cache-recovery.md` — member 8 design: the `reload_schema_cache!` helper + the `schema_cache_per_tenant` load-path fix (#455).
- `docs/designs/reading-role-test-support.md` — the `:reading` role axis (shipped) and member 10 origin.
- `docs/upgrading-to-v4.md` — upgrade guide; already covers alpha3+ pool config.
- `RELEASING.md` — Model A release flow; `main` squash-only, release branches merge-commit-only.
- `.github/workflows/ci.yml` — CI matrix; target for the W4 PgBouncer service container.

## Origin

2026-06-28 alpha→beta framing conversation. The maintainer chose a pragmatic API posture but a complete correctness floor: members 7/8/9 to be tested before beta, the PgBouncer libpq path implemented, and beta gated on the adopter's real `:reading`-separated rollout. Member 8 was subsequently reclassified (2026-06-29 brainstorm): v4's pool-per-tenant already isolates schema caches per pool, so it shipped as a minimal recovery helper (#455) rather than a tested failure class. Member 10's eventual fix remains deferred pending adopter evidence. See the Progress section for current status; this section records the original framing.
