# v4 Beta Readiness

Status: living. Defines what "beta" means for `ros-apartment` v4 and the scoped, prioritized workstreams that gate it. Created from the 2026-06-28 alpha→beta framing conversation; current version `4.0.0.alpha5`.

## Progress (updated 2026-06-29)

- **W5 — Cursor debt** ✅ shipped (#453): physical-name validation seam + advisory-lock ivar guard. Plus a review-driven follow-up (#454): validate pool-key-unsafe tenant names before admission/eviction.
- **W2 — Member 8** ✅ reactive half shipped (#455): the brainstorm collapsed this from the "design-first long pole" to a minimal `Apartment::Tenant.reload_schema_cache!` helper + a fix for the latent `schema_cache_per_tenant` load path. v4's pool-per-tenant already isolates schema caches and AR self-heals prepared statements, so the residual was only the shared/pinned-table amplifier. Design: `docs/designs/v4-schema-cache-recovery.md`.
- **Remaining beta-blocking**: W1 (member 7), W3 (member 9), W4 (PgBouncer libpq), W6 (adopter `:reading` rollout), then Track C packaging.
- **Critical path now**: with member 8 closed, the internal long pole is W4 (PgBouncer); the overall beta date is bounded below by the adopter `:reading`-separated rollout (W6).

## TLDR

**Beta = pragmatic posture on a correctness-complete floor.** We tell a new adopter "run v4 in staging" (documented-stable API with named escape hatches; *not* a GA-binding API freeze), but only once every *suspected* failure class is tested, the advertised PgBouncer/RDS-Proxy compatibility is actually implemented (not aspirational), and the primary adopter has exercised the real `:reading`-separated path. The posture is light; the floor is heavy. Almost all v4 engineering already shipped across alpha1–5 — beta is a correctness-closure + decision + documentation milestone, with **one remaining internal code long pole (the PgBouncer libpq path)** and one external dependency (the adopter's rollout timeline). (Member 8, originally scoped as a second long pole, shipped in #455 as a minimal recovery helper once the brainstorm found v4 already isolates schema caches per pool — see Progress.)

## What beta means here (the decision)

A multi-tenancy gem the maintainer's own product runs in production can't ship a beta that "mostly works." Two independent axes, decided separately:

- **API-stability posture: pragmatic.** Beta does *not* freeze the public API to GA. We publish a soft deprecation promise and reserve named escape hatches. Rationale: v4 is a clean break already; over-committing to API permanence before real-adopter feedback is premature, and the pragmatic signal ("try it in staging") is the honest one.
- **Correctness floor: complete.** No *untested* suspected failure class ships in beta. The PgBouncer transaction-mode compatibility v4 advertised as a goal is real. The primary adopter has run the path that exercises the gem's hardest seam (`:reading` on a distinct pool). Rationale: correctness gaps in tenant isolation are silent and catastrophic; "beta" must not paper over known-suspected ones.

This split is the whole design: **loose on promises, strict on behavior.**

## The four gates

1. **API surface + deprecation policy.** Public API (`Apartment::Tenant.*`, `Apartment.configure` keys, elevator classes, `Apartment::Model`/`pin_tenant`, notification event names, error hierarchy) is documented as the beta surface, with a one-paragraph soft deprecation policy. Lock the pool-knob config names that moved during the alphas (`tenant_pool_size` default 5→nil, `pool_overflow_policy`, `reap_in_test`, `reaper_interval`). No new written stability statement exists today — this gate creates it.

2. **Docs + upgrade-guide completeness.** README, `upgrading-to-v4.md`, and per-feature docs (adapters, elevators, caching, observability, testing) exist and cover alpha5 config. Beta adds a getting-started→production checklist, makes the async-query consumer-fiber contract prominent, and rewrites the PgBouncer section to the *implemented* state (see W4) rather than documenting a gap.

3. **Known-gap triage — every gap gets a verdict.** Failure-class members 7/8/9/10, the (now-closed) Cursor PR-review backlog, and the libpq path. Disposition below. Decision: **7 and 9 are tested before beta** (not documented-and-deferred); **8 was reclassified and mitigated** — the brainstorm found v4 already isolates schema caches per pool, so #455 shipped a minimal recovery helper + load-path fix rather than a failure-class integration test; 10 ships a cheap test-env workaround with the apartment-side fix deferred to adopter-reported need; the libpq path is implemented. The Cursor backlog closed with W5 (#453/#454).

4. **Real-adopter green at depth.** The primary adopter's v4 migration is CI-green on the `:reading`-separated rollout path — the phase that puts a tenant's `:reading` role on its own pool and thereby exercises member 10 for real. Green at the earlier (Phase 0/1) rollout is *not* sufficient for beta. This gate is externally paced.

## Resolved decisions

| Question | Decision | Consequence |
|----------|----------|-------------|
| Beta posture | Pragmatic (try-in-staging) | Soft deprecation policy, not a GA-binding freeze (W8) |
| Adopter-green depth | Wait for `:reading`-separated rollout | Beta date bounded below by the adopter's rollout timeline (W6); surfaces member 10 for real |
| Members 7 & 9 | Test before beta | W1/W3 are beta-blocking, not deferred (member 8 split out — see below) |
| PgBouncer libpq path | Implement before beta | W4 is beta-blocking |
| PgBouncer CI | Free via service container | Public-repo runners are free; add a `pgbouncer` service to `ci.yml` — no spend, just config |
| Member 8 design depth | Resolved (#455) — minimal helper, not full invalidation | Brainstorm showed v4 already isolates schema caches per pool; shipped a manual recovery helper + load-path fix |
| Member 10 | Cheap test-env guard now (force read→`:writing` in test) | Apartment-side fix built only on adopter-reported replica-read-test need |

## Scoped workstreams

Three tracks. Size is relative (S/M/L). Long poles flagged.

### Track A — Correctness (beta-blocking)

- **W1 — Member 7, `PQTRANS_INERROR` taint** (M). Instrumented detection + recovery in `Apartment::Tenant.switch`'s ensure block, plus an integration spec. PG-specific error state; the downstream best-effort `ROLLBACK` loop is the evidence the variant bites. See `fixture-pool-lifecycle.md` member 7.
- **W2 — Member 8, schema-cache / prepared-statement drift after tenant DDL** ✅ **shipped (#455)**. The brainstorm showed v4's pool-per-tenant already isolates schema caches per pool and AR self-heals prepared statements, collapsing the original long-pole scope. Shipped: the manual `Apartment::Tenant.reload_schema_cache!` recovery helper for the pinned/shared-table-DDL amplifier, plus a fix for the latent `schema_cache_per_tenant` load path. Design: `docs/designs/v4-schema-cache-recovery.md`.
- **W3 — Member 9, within-process thread/job boundaries** (M). Sidekiq-inline, async executors, `parallel_tests` workers, and app-level threads that `switch` a tenant inside a worker thread may resolve pools differently from the originating thread. Likely resolves to a documented contract + a helper, plus coverage — not only a spec.
- **W4 — PgBouncer libpq `options` (approach 1)** (M–L, long pole). Set `search_path` at the protocol level via the libpq connection-string `options: '-c search_path=tenant,ext,public'` so no `SET` runs at connection establishment, eliminating the residual single-pin; fall back to `schema_search_path` when the driver doesn't support it. Verification needs a PgBouncer transaction-mode harness in CI — feasible free via a service container. Spike the `ruby-pg` `options:` support across PG 16/18 as the plan's first step.
- **W5 — Cursor debt: advisory-lock fragility + raw-tenant validation** ✅ **shipped (#453, follow-up #454)**. Added a `physical_tenant_name` validation seam (pool-resolution validates the identifier the connection actually targets) and guarded the `@advisory_locks_enabled` ivar poke with a rename-detecting contract test. Follow-up #454 moved pool-key-unsafe-name rejection ahead of admission/eviction.

### Track B — Adopter validation (external-gated long pole)

- **W6 — Adopter `:reading`-separated rollout green** (—). The primary adopter's v4 migration CI-green on the rollout phase that routes `:reading` to a distinct pool. Externally paced; coordinate now. Bounds the beta date from below; with member 8 closed, this and W4's duration are what remain.
- **W7 — Member 10 disposition** (S now / L if-fix). Ship the cheap test-env guard (force `read_only_query`→`:writing` under `Rails.env.test?`; no gem change) as the supported answer now. Build the apartment-side fix (connection-share tenant `:reading` pools under fixtures) *only* if the adopter reports a need for replica-read test fidelity — historically rare. Resolves when W6 surfaces the behavior for real.

### Track C — Beta packaging (finalize last)

- **W8 — API-freeze decision + deprecation-policy paragraph** (S). Pragmatic-posture wording; lock the pool-knob config names. Finalize after W1/W3/W4 settle the surface (W2/W5 already settled).
- **W9 — Docs completeness** (M). Production checklist; prominent async consumer-fiber contract; PgBouncer section rewritten to the implemented W4 state. Depends on W4 landing.
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
