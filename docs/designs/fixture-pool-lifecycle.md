# Fixture Pool Lifecycle

Status: living. Last consolidated 2026-05-15 after PR #400, a downstream flake report, and three-CLI review.

## TLDR

Pool-lifecycle APIs invoked while Rails owns a fixture transaction can produce silent test pollution. The reaper variant of this class is closed (#399 pinned guard, #400 in-use guard). One member remains in active investigation (`reset_tenant_pools!` mid-suite); one is suspected but unproven (lazy pool creation after `setup_fixtures` without a prior reset). The plan: one invariant in code, one escape hatch, one integration spec that gates a contingent third fix.

## The invariant

Pool lifecycle changes during fixture-transaction ownership are a violation.

In code form: when Rails' transactional fixtures own one or more pools (detected via the `@pinned_connection` ivar that `ConnectionPool#pin_connection!` sets), no Apartment API should discard or replace those pools. Tests that need to cycle pools opt out of fixture transactions explicitly.

This is the broader rule the in-use guard from #400 specialized for the reaper case. Generalizing it to other lifecycle APIs is the work in scope here.

## Failure class members

| # | Member | Status | Mechanism |
|---|---|---|---|
| 1 | Reaper evicts pinned pool | Closed (#399) | `PoolReaper` removed the pool that fixtures had pinned for rollback. |
| 2 | Reaper evicts pool with in-flight tx | Closed (#400) | `PoolReaper` removed a pool with leased connections or open transactions. |
| 3 | `reset_tenant_pools!` mid-suite | Open, mechanism inferred | Cleanup hook discards tenant pools; next example's `setup_fixtures` snapshots `connection_pool_list` without them; lazy-recreated pools have new object identity and don't enroll in the fixture tx. |
| 4 | Lazy create after `setup_fixtures` (no reset) | Suspected, unproven | First `switch(:foo)` in example body materializes a pool post-snapshot. May or may not enroll. The integration spec settles this. |
| 5 | Non-`:writing` roles / replicas | Suspected | `connection_pool_list` semantics differ in multi-DB / multi-role setups; the invariant must hold per handler, not globally. |
| 6 | Parallel-example concurrency | Out of scope here | Order-dependent flakes and concurrent flakes are different families; this doc tracks the order-dependent class only. |
| 7 | `PQTRANS_INERROR` taint after schema mutation | Suspected (downstream evidence) | Downstream consumers have shipped best-effort `ROLLBACK` loops in cross-tenant test cleanup. Existence of the workaround pattern is evidence the variant bites; gem-side coverage deferred. |
| 8 | Schema cache / prepared-statement drift after tenant DDL | Suspected | Pinned-model joins after DDL in one tenant may resolve against stale caches in another. |
| 9 | Within-process thread / job boundaries | Suspected | Sidekiq inline, async executors, parallel_tests workers, or app-level threads that `switch` a tenant inside a worker thread may resolve pools differently from the originating thread. Different family from #6 (RSpec parallel examples). |

Members 1 and 2 stay closed. 3 and 4 are the active work. 5–9 are tracked but not in scope this iteration.

## Now (this iteration)

Scope: one PR after the integration spec lands red and turns green.

1. **Integration spec**: `spec/integration/v4/fixture_pool_lifecycle_spec.rb` against the dummy Rails app. Asserts pool object identity (not tenant name) across the reset → recreate boundary; verifies rollback (not just visibility, since a leased connection can pass writes while rollback still fails later); tests the non-reset lazy path as a first-class case to settle the (a′) question below; covers Rails 7.2, 8.0, 8.1 in the existing matrix.

2. **`reset_tenant_pools!` guard**: refuse the call when any pool in `Apartment.pool_manager` carries `@pinned_connection`, raising `Apartment::FixtureLifecycleViolation` (a new subclass of `Apartment::ApartmentError`) with a message naming the offending tenant and pointing at the truncation strategy below. Test-env-scoped via `Rails.env.test?`; production keeps the existing semantics. Detection primitive is the same `@pinned_connection` ivar `pool_pinned?` already reads in `lib/apartment/pool_reaper.rb:164-168` — no new heuristics.

   Contract-locked error text:

   ```
   Apartment::FixtureLifecycleViolation: reset_tenant_pools! called while pool
   'acme:writing' is pinned by transactional fixtures. Use
   Apartment::Test::Truncation for cross-tenant specs that must cycle pools.
   See docs/designs/fixture-pool-lifecycle.md.
   ```

3. **`docs/testing.md` invariant section**: opens with the v3→v4 posture (v3's pain was a variable problem — which `search_path` is current; v4's pain is a resource lifecycle problem — does the pool still exist with the object identity fixtures enrolled), then states the rule in one line, then points at this design doc for the failure-class detail. Consumers landing on the constraint without the model can't generalize it to future variants; the framing gives them the model.

4. **Downstream cleanup-pattern deletions**: once #1–3 land, three workaround patterns shipped by downstream consumers become delete-candidates — the `reset_tenant_pools!` call in cross-tenant cleanup, the companion best-effort `ROLLBACK` loop guarding against `PQTRANS_INERROR` taint, and any manual eager-load stubs added to work around the resulting query pollution. The gem-side guard lands here; downstream removals follow on the consumer's own timeline.

   Kept-on-purpose (not in scope for deletion): around-hook helpers like `with_tenants` that consumers wrap test suites in to define a tenant set without cycling pools mid-test. These are consumer ergonomics, not workarounds for gem bugs, and survive the cleanup. Naming the category here prevents a future contributor from re-litigating its existence.

## Eventually (within a month, evidence-gated)

5. **`Apartment::Test::Truncation` strategy** (the escape hatch). Programmatic opt-out from fixture transactions for specs that must cycle pools. Two open shapes:
   - RSpec metadata flag (`cross_tenant: true`) that flips `use_transactional_fixtures = false` for the marked example and registers a per-example truncation cleaner.
   - A `helper include Apartment::Test::CrossTenant` that does the same via setup/teardown hooks.

   The shape needs its own design conversation before implementation — flipping `use_transactional_fixtures` per-example touches Rails internals that may shift across versions. Treat #5 as design-then-build, not build-then-document.

6. **`Apartment::Tenant.preload_test_pools!`** (the contingent fix). Opt-in helper that walks `tenants_provider` and materializes pools before the first `setup_fixtures` runs. Only built if step #1 proves the non-reset lazy path is broken on its own (i.e., step 4 of the integration spec lands red). If the lazy path enrolls correctly, this is YAGNI and stays unbuilt.

   The helper is opt-in only: auto-invoke from the railtie is rejected (see Never #2).

7. **Multi-handler / multi-role variants of the integration spec**. Parametrize over `:writing` and `:reading` roles once the dummy app supports replicas. Deferred until reading replicas are exercised in the main matrix — not blocking #1–4.

## Never

These are explicit rejections, with the reason recorded so they don't get re-litigated.

1. **Re-enroll lazy pools at switch time** (the original (a) shape). Hooking AR's `TestFixtures` rollback path symmetrically to enroll pools created mid-test fights AR internals that aren't designed for dynamic mid-transaction pool registration. Race-prone, version-fragile, and the same correctness budget buys #6 (`preload_test_pools!`) more cleanly.

2. **Auto-invoke `preload_test_pools!` from the railtie**. `tenants_provider` may DB-query at boot, or reference tenants that don't yet exist. Opt-in is the contract; the gem doesn't decide preload semantics for the consumer.

3. **Bypass fixture transactions on the gem's side without explicit user opt-in**. Test isolation strategy belongs to the consumer; the gem refuses to silently change it. The truncation strategy (#5) requires explicit metadata or include.

4. **Patch `connection_pool_list` to dynamically include lazy pools**. AR's snapshot semantics are deliberate; subverting them at the consumer's expense breaks isolation contracts elsewhere (savepoint enrollment, role resolution, role-specific pool lookup). #6 achieves the right outcome at fixture-setup time without monkey-patching AR.

5. **Test-mode `SET search_path` switching** (rejected previously in `v4-test-fixtures-compatibility.md`). Re-introduces the runtime search_path mutation v4 eliminated; undermines pool-per-tenant as the production code path.

## Wishlist (>1 month, deferred)

Items the broader-class observation surfaced but that need their own design conversations before they enter a roadmap.

- **Parallel-spec safety hardening**. Order-dependent flakes (this doc) and concurrent flakes are different families. Process-scoping the `reset_tenant_pools!` guard is one piece; broader concurrent-fixture-tx semantics is its own investigation.
- **`PQTRANS_INERROR` recovery hooks**. The downstream `ROLLBACK` loop is evidence the variant exists. Gem-side coverage would mean an instrumented detection + recovery path, probably in `Apartment::Tenant.switch`'s ensure block. Real but lower priority than #1–6.
- **Schema cache invalidation on tenant DDL**. Pinned-model joins after one tenant's DDL may resolve against stale caches. Needs adapter-specific design (PG vs MySQL diverge on cache invalidation primitives).
- **Adapter-specific savepoint behavior**. PG schema adapter under `pin_connection!` with DDL inside a tenant tx may detach the savepoint stack. Sanity check inside the integration spec is in scope (#1); deeper coverage is wishlist.
- **`with_tenants_provider`-style scoped overrides for test fixtures**. Currently tracked in `docs/plans/with-tenants-provider/`. Adjacent but separate work.

## Decisions and probabilities

Aggregate after three-CLI review (cursor / codex / gemini) and downstream agreement:

- 0.45 — Ship #1 (integration spec), #2 (`reset_tenant_pools!` guard), #3 (docs invariant) now; #5 and #6 follow, with #6 gated on what #1 finds.
- 0.37 — Same as above but ship #6 (`preload_test_pools!`) together with #2 without waiting on evidence. Justified if cost of waiting is high and one round-trip is preferred. Both cursor and codex flagged that "working multi-tenant suites" is weak evidence for #6 being unnecessary — preload patterns and accidental ordering can paper over the lazy-without-reset path.
- 0.18 — Anything that makes #2 optional. Including the original "(a′) + (c) with (b) as supporting guardrail" lean. Rejected on grounds that the invariant being optional defeats the framing.

Cross-CLI convergence on the YAGNI softening for #6 nudged the 0.45 path down from an initial 0.50 and lifted 0.37 from 0.32: two independent reviewers flagging the same risk is stronger signal than the original lean, and the bias-correction toward "do the cheap additive fix" deserves real weight. 0.45 is still preferred for evidence discipline, but the gap is narrower than the first cut suggested.

## Detection primitives

Where the invariant lives in code:

- `ConnectionPool#pin_connection!` (Rails 7.1+) sets `@pinned_connection`. Apartment reads this ivar in `lib/apartment/pool_reaper.rb:164-168` via `pool_pinned?`. The `reset_tenant_pools!` guard (#2) reuses the same primitive; no new heuristics.
- `ConnectionPool#in_use?` and `Connection#open_transactions` (public API). Reaper already uses these for the in-use guard (`pool_in_use?` at `lib/apartment/pool_reaper.rb:175-182`). Available for any future lifecycle guard.
- `ActiveRecord::Base.connection_handler.connection_pool_list(:all)` — snapshot consumed by fixture machinery. Read-only from Apartment's side; do not mutate.

Across Rails 7.2 / 8.0 / 8.1 the `@pinned_connection` semantics are stable. 8.x+ may rename or refactor; the integration spec covers all matrix versions, and any divergence surfaces there.

## Cross-references

- `docs/designs/v4-test-fixtures-compatibility.md` — the `setup_shared_connection_pool` patch (PRs #379, #380). This doc generalizes that work to other lifecycle APIs.
- `docs/testing.md` — consumer-facing summary of the invariant and the available test helpers. Updated as part of #3.
- `lib/apartment/pool_reaper.rb` — existing pinned and in-use guards (PRs #399, #400). The `reset_tenant_pools!` guard reuses the same detection primitives.
- `docs/plans/with-tenants-provider/` — adjacent test-fixtures work tracked separately.

## Origin

PR #400 closed the reaper variant of the failure class. A downstream consumer bumped to `a89aa0b` and reported a remaining order-dependent flake, bisected to a `reset_tenant_pools!` call in a `cross_tenant` shared context. Three-CLI consultation (cursor, codex, gemini) converged on (b) as the load-bearing invariant and on (a′) as evidence-gated, with several additions absorbed into the inventory above.
