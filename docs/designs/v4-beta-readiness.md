# v4 Beta Readiness

Status: living. Defines what "beta" means for `ros-apartment` v4 and the scoped, prioritized workstreams that gate it. Created from the 2026-06-28 alpha→beta framing conversation; current version `4.0.0.alpha5`.

## TLDR

**Beta = pragmatic posture on a correctness-complete floor.** We tell a new adopter "run v4 in staging" (documented-stable API with named escape hatches; *not* a GA-binding API freeze), but only once every *suspected* failure class is tested, the advertised PgBouncer/RDS-Proxy compatibility is actually implemented (not aspirational), and the primary adopter has exercised the real `:reading`-separated path. The posture is light; the floor is heavy. Almost all v4 engineering already shipped across alpha1–5 — beta is a correctness-closure + decision + documentation milestone, with two genuine code long poles (member 8 schema-cache drift; PgBouncer libpq path) and one external dependency (the adopter's rollout timeline).

## What beta means here (the decision)

A multi-tenancy gem the maintainer's own product runs in production can't ship a beta that "mostly works." Two independent axes, decided separately:

- **API-stability posture: pragmatic.** Beta does *not* freeze the public API to GA. We publish a soft deprecation promise and reserve named escape hatches. Rationale: v4 is a clean break already; over-committing to API permanence before real-adopter feedback is premature, and the pragmatic signal ("try it in staging") is the honest one.
- **Correctness floor: complete.** No *untested* suspected failure class ships in beta. The PgBouncer transaction-mode compatibility v4 advertised as a goal is real. The primary adopter has run the path that exercises the gem's hardest seam (`:reading` on a distinct pool). Rationale: correctness gaps in tenant isolation are silent and catastrophic; "beta" must not paper over known-suspected ones.

This split is the whole design: **loose on promises, strict on behavior.**

## The four gates

1. **API surface + deprecation policy.** Public API (`Apartment::Tenant.*`, `Apartment.configure` keys, elevator classes, `Apartment::Model`/`pin_tenant`, notification event names, error hierarchy) is documented as the beta surface, with a one-paragraph soft deprecation policy. Lock the pool-knob config names that moved during the alphas (`tenant_pool_size` default 5→nil, `pool_overflow_policy`, `reap_in_test`, `reaper_interval`). No new written stability statement exists today — this gate creates it.

2. **Docs + upgrade-guide completeness.** README, `upgrading-to-v4.md`, and per-feature docs (adapters, elevators, caching, observability, testing) exist and cover alpha5 config. Beta adds a getting-started→production checklist, makes the async-query consumer-fiber contract prominent, and rewrites the PgBouncer section to the *implemented* state (see W4) rather than documenting a gap.

3. **Known-gap triage — every gap gets a verdict.** Failure-class members 7/8/9/10, the residual Cursor PR-review backlog, and the libpq path. Disposition below. Decision: **7, 8, 9 are tested before beta** (not documented-and-deferred); 10 ships a cheap test-env workaround with the apartment-side fix deferred to adopter-reported need; the libpq path is implemented.

4. **Real-adopter green at depth.** The primary adopter's v4 migration is CI-green on the `:reading`-separated rollout path — the phase that puts a tenant's `:reading` role on its own pool and thereby exercises member 10 for real. Green at the earlier (Phase 0/1) rollout is *not* sufficient for beta. This gate is externally paced.

## Resolved decisions

| Question | Decision | Consequence |
|----------|----------|-------------|
| Beta posture | Pragmatic (try-in-staging) | Soft deprecation policy, not a GA-binding freeze (W8) |
| Adopter-green depth | Wait for `:reading`-separated rollout | Beta date bounded below by the adopter's rollout timeline (W6); surfaces member 10 for real |
| Members 7/8/9 | Test all three before beta | W1/W2/W3 are beta-blocking, not deferred |
| PgBouncer libpq path | Implement before beta | W4 is beta-blocking |
| PgBouncer CI | Free via service container | Public-repo runners are free; add a `pgbouncer` service to `ci.yml` — no spend, just config |
| Member 8 design depth | Open — research + brainstorm first | W2 is design-first; scope finalizes after its own brainstorm pass |
| Member 10 | Cheap test-env guard now (force read→`:writing` in test) | Apartment-side fix built only on adopter-reported replica-read-test need |

## Scoped workstreams

Three tracks. Size is relative (S/M/L). Long poles flagged.

### Track A — Correctness (beta-blocking)

- **W1 — Member 7, `PQTRANS_INERROR` taint** (M). Instrumented detection + recovery in `Apartment::Tenant.switch`'s ensure block, plus an integration spec. PG-specific error state; the downstream best-effort `ROLLBACK` loop is the evidence the variant bites. See `fixture-pool-lifecycle.md` member 7.
- **W2 — Member 8, schema-cache / prepared-statement drift after tenant DDL** (L, **design-first**). Pinned-model joins after one tenant's DDL may resolve against stale caches in another. **Needs its own brainstorm/design pass before it is plan-able** — PG and MySQL diverge on cache-invalidation primitives, so the scope (full adapter-specific invalidation vs. a documented cache-bust API + narrower guard) is an open design question. Longest internal pole; start its design early.
- **W3 — Member 9, within-process thread/job boundaries** (M). Sidekiq-inline, async executors, `parallel_tests` workers, and app-level threads that `switch` a tenant inside a worker thread may resolve pools differently from the originating thread. Likely resolves to a documented contract + a helper, plus coverage — not only a spec.
- **W4 — PgBouncer libpq `options` (approach 1)** (M–L, long pole). Set `search_path` at the protocol level via the libpq connection-string `options: '-c search_path=tenant,ext,public'` so no `SET` runs at connection establishment, eliminating the residual single-pin; fall back to `schema_search_path` when the driver doesn't support it. Verification needs a PgBouncer transaction-mode harness in CI — feasible free via a service container. Spike the `ruby-pg` `options:` support across PG 16/18 as the plan's first step.
- **W5 — Cursor debt: advisory-lock fragility + raw-tenant validation** (S). Replace the `instance_variable_get/set(:@advisory_locks_enabled)` toggle in `migrator.rb` with a less Rails-upgrade-fragile mechanism (or a guarded/tested wrapper); fix `validated_connection_config` validating the raw tenant on the pool-resolution path (needs a per-adapter override — `PostgreSQLSchemaAdapter` uses raw `tenant`, database-per-tenant adapters use `environmentify(tenant)`). Both precisely located; zero design ambiguity.

### Track B — Adopter validation (external-gated long pole)

- **W6 — Adopter `:reading`-separated rollout green** (—). The primary adopter's v4 migration CI-green on the rollout phase that routes `:reading` to a distinct pool. Externally paced; coordinate now. Bounds the beta date from below alongside W2.
- **W7 — Member 10 disposition** (S now / L if-fix). Ship the cheap test-env guard (force `read_only_query`→`:writing` under `Rails.env.test?`; no gem change) as the supported answer now. Build the apartment-side fix (connection-share tenant `:reading` pools under fixtures) *only* if the adopter reports a need for replica-read test fidelity — historically rare. Resolves when W6 surfaces the behavior for real.

### Track C — Beta packaging (finalize last)

- **W8 — API-freeze decision + deprecation-policy paragraph** (S). Pragmatic-posture wording; lock the pool-knob config names. Finalize after W1–W5 settle the surface.
- **W9 — Docs completeness** (M). Production checklist; prominent async consumer-fiber contract; PgBouncer section rewritten to the implemented W4 state. Depends on W4 landing.
- **W10 — Open-issue enumeration + triage sweep** (S). Confirm the public tracker has nothing beta-blocking open before declaring triage clean. (`gh issue list` returned empty in the framing check — re-verify.)

## Critical path & sequencing

W2 (member 8, design-first) and W4 (PgBouncer) are the internal long poles — both start now; W2 begins with a brainstorm, W4 with a driver-support spike. W6 (adopter) runs the whole window, externally paced. W1/W3/W5 are independent and parallelizable. Track C closes last, once W1–W5 lock behavior.

**Beta date is bounded below by `max(member-8 design+impl, adopter `:reading`-separated rollout green)`.** Everything else fits inside that envelope.

Suggested order of plans: **W5 first** (smallest, zero-ambiguity, clears two debt items, fast green), in parallel kick off the **member-8 (W2) brainstorm** (longest pole, needs design before a plan), then **W4** (other long pole, now CI-unblocked), then W1/W3, then Track C.

## Cross-references

- `docs/designs/apartment-v4.md` — v4 architecture; PgBouncer approach-1 (still unimplemented), async-query correctness contract, notification events, error hierarchy.
- `docs/designs/fixture-pool-lifecycle.md` — failure-class members 7/8/9/10 (suspected) and the closed members 1–5.
- `docs/designs/reading-role-test-support.md` — the `:reading` role axis (shipped) and member 10 origin.
- `docs/upgrading-to-v4.md` — upgrade guide; already covers alpha3+ pool config.
- `RELEASING.md` — Model A release flow; `main` squash-only, release branches merge-commit-only.
- `.github/workflows/ci.yml` — CI matrix; target for the W4 PgBouncer service container.

## Origin

2026-06-28 alpha→beta framing conversation. The maintainer chose a pragmatic API posture but a complete correctness floor: members 7/8/9 tested before beta, the PgBouncer libpq path implemented, and beta gated on the adopter's real `:reading`-separated rollout. Member 8's design depth and member 10's eventual fix are deliberately left open pending research and adopter evidence respectively.
