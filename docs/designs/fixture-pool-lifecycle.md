# Fixture Pool Lifecycle

Status: living. Last consolidated 2026-05-19 after PRs #399, #400, and #403 (which squashed the `reset_tenant_pools!` guard, the integration spec, and the docs invariant section onto `main` as `abcf755`).

## TLDR

Pool-lifecycle APIs invoked while Rails owns a fixture transaction can produce silent test pollution. Members 1–4 of the failure class are closed: the reaper guards (#399 pinned, #400 in-use), the `reset_tenant_pools!` guard (`abcf755`), and the (a′) lazy-enrollment probe — the integration spec is green on Rails 7.2 / 8.0 / 8.1 + PG, re-verified 2026-05-19. The contingent `preload_test_pools!` helper retires as YAGNI on the same evidence. The escape-hatch piece (originally "`Apartment::Test::Truncation`") closes as docs-only: a three-CLI panel + guard-scope verification settled that `use_transactional_tests = false` is the Rails-native opt-out, and the existing guard already scopes to tenant pools. The recipe lives in [`docs/testing.md` § Cycling pools mid-suite](../testing.md#cycling-pools-mid-suite).

## The invariant

Pool lifecycle changes during fixture-transaction ownership are a violation.

In code form: when Rails' transactional fixtures own one or more pools (detected via the `@pinned_connection` ivar that `ConnectionPool#pin_connection!` sets), no Apartment API should discard or replace those pools. Tests that need to cycle pools opt out of fixture transactions explicitly.

This is the broader rule the in-use guard from #400 specialized for the reaper case. Generalizing it to other lifecycle APIs is the work in scope here.

## Failure class members

| # | Member | Status | Mechanism |
|---|---|---|---|
| 1 | Reaper evicts pinned pool | Closed (#399) | `PoolReaper` removed the pool that fixtures had pinned for rollback. |
| 2 | Reaper evicts pool with in-flight tx | Closed (#400) | `PoolReaper` removed a pool with leased connections or open transactions. |
| 3 | `reset_tenant_pools!` mid-suite | Closed (`abcf755`) | Cleanup hook discards tenant pools; next example's `setup_fixtures` snapshots `connection_pool_list` without them; lazy-recreated pools have new object identity and don't enroll in the fixture tx. Guard raises `Apartment::FixtureLifecycleViolation` in test env. |
| 4 | Lazy create after `setup_fixtures` (no reset) | Closed (`abcf755`; re-verified 2026-05-19) | First `switch(:foo)` in example body materializes a pool post-snapshot. Integration spec's (a′) tiebreaker asserts rollback (not just visibility) of rows written via lazy pools; green on Rails 7.2 / 8.0 / 8.1 + PG. Lazy enrollment is reliable. |
| 5 | Non-`:writing` roles / replicas | Suspected | `connection_pool_list` semantics differ in multi-DB / multi-role setups; the invariant must hold per handler, not globally. |
| 6 | Parallel-example concurrency | Out of scope here | Order-dependent flakes and concurrent flakes are different families; this doc tracks the order-dependent class only. |
| 7 | `PQTRANS_INERROR` taint after schema mutation | Suspected (downstream evidence) | Downstream consumers have shipped best-effort `ROLLBACK` loops in cross-tenant test cleanup. Existence of the workaround pattern is evidence the variant bites; gem-side coverage deferred. |
| 8 | Schema cache / prepared-statement drift after tenant DDL | Suspected | Pinned-model joins after DDL in one tenant may resolve against stale caches in another. |
| 9 | Within-process thread / job boundaries | Suspected | Sidekiq inline, async executors, parallel_tests workers, or app-level threads that `switch` a tenant inside a worker thread may resolve pools differently from the originating thread. Different family from #6 (RSpec parallel examples). |

Members 1–4 are closed; the workstream's escape-hatch question (originally tracked as workstream item 6) is closed docs-only — see Shipped #6. Failure-class members 5, 7, 8, 9 are tracked but not in scope this iteration. The next active piece of work is the multi-handler / `:reading` variant (Eventually #7), gated on the dummy app gaining replicas.

## Shipped

Failure-class members 1–4 and the workstream's escape-hatch resolution. Detail kept here so future contributors can find the work without git archaeology.

1. **Reaper pinned-pool guard** (#399). `PoolReaper` skips pools where `pool_pinned?` returns true. Detection lives in `lib/apartment/pool_reaper.rb:164-168`.

2. **Reaper in-use guard** (#400). `PoolReaper` skips pools with leased connections or open transactions via `pool_in_use?` at `lib/apartment/pool_reaper.rb:175-182`.

3. **`reset_tenant_pools!` guard** (`abcf755`, via PR #403's squash; PR #402 was closed as merged-via-#403 after a branching mistake). Refuses the call when any pool carries `@pinned_connection`, raising `Apartment::FixtureLifecycleViolation` (defined at `lib/apartment/errors.rb:47`). Test-env-scoped via `Rails.env.test?`; production keeps existing semantics. Reuses the same `@pinned_connection` detection primitive — no new heuristics.

   Contract-locked error text (asserted by the integration spec):

   ```
   Apartment::FixtureLifecycleViolation: reset_tenant_pools! called while pool
   'acme:writing' is pinned by transactional fixtures. To cycle pools mid-suite,
   disable transactional fixtures for this test (use_transactional_tests = false)
   and clean up by deletion. See docs/testing.md.
   ```

   The message previously pointed at an `Apartment::Test::Truncation` module on the roadmap. Member 6 (workstream item) is now closed as docs-only — see [docs/testing.md § Cycling pools mid-suite](../testing.md#cycling-pools-mid-suite) for the recipe. The message text was updated in lockstep so the violation directs users to the actual documented opt-out.

4. **Integration spec** (`spec/integration/v4/fixture_pool_lifecycle_spec.rb`, `abcf755`). Five examples cover the guard, the contract-locked message, the negative case, the pool-identity mechanism, and the (a′) tiebreaker. Re-verified 2026-05-19: green on Rails 7.2 / 8.0 / 8.1 + PG, all matrix versions. The (a′) result settles member 6: lazy enrollment is reliable, `preload_test_pools!` stays unbuilt (see Never #6).

5. **`docs/testing.md` invariant section** (`abcf755`). Opens with the v3→v4 posture (v3's pain was a variable problem — which `search_path` is current; v4's pain is a resource lifecycle problem — does the pool still exist with the object identity fixtures enrolled), then states the rule and points back here.

6. **Escape hatch for specs that cycle pools** (closed 2026-05-19, docs-only). The originally-scoped item was "ship `Apartment::Test::Truncation` / `Apartment::Test::CrossTenant` as code." A three-CLI panel (codex / gemini / cursor) converged on Rails' `self.use_transactional_tests = false` as the supported opt-out across the 7.2 / 8.0 / 8.1 matrix; an inspection of `Apartment.guard_pinned_pools_during_fixtures!` confirmed the guard iterates `@pool_manager.each_pair` only — primary is never checked, so the surgical "guard scopes to tenant pools" path is already in place by construction. The hatch is therefore the opt-out itself; cleanup is a documented recipe (`DatabaseCleaner.strategy = :deletion` + `clean_pinned_models!` + `reset_tenant_pools!` last). Recipe: [`docs/testing.md` § Cycling pools mid-suite](../testing.md#cycling-pools-mid-suite). Rejection of the code-shipping shapes recorded in Never #7.

Downstream cleanup that becomes delete-candidates with these guards in place: the `reset_tenant_pools!` call in cross-tenant test cleanup, the companion best-effort `ROLLBACK` loop guarding `PQTRANS_INERROR` taint, and manual eager-load stubs added to work around the resulting query pollution. Consumer removals are on their own timeline. Kept-on-purpose: around-hook helpers like `with_tenants` that define a tenant set without cycling pools mid-test — these are ergonomics, not workarounds.

## Eventually (>1mo, deferred)

7. **Multi-handler / multi-role variants of the integration spec**. Parametrize over `:writing` and `:reading` roles once the dummy app supports replicas. Deferred until reading replicas are exercised in the main matrix.

## Never

These are explicit rejections, with the reason recorded so they don't get re-litigated.

1. **Re-enroll lazy pools at switch time** (the original (a) shape). Hooking AR's `TestFixtures` rollback path symmetrically to enroll pools created mid-test fights AR internals that aren't designed for dynamic mid-transaction pool registration. Race-prone, version-fragile, and made redundant by the (a′) tiebreaker outcome — lazy enrollment already works.

2. **Bypass fixture transactions on the gem's side without explicit user opt-in**. Test isolation strategy belongs to the consumer; the gem refuses to silently change it. The documented opt-out (workstream item 6) is Rails' `self.use_transactional_tests = false` — explicit, at the consumer's site, in a primitive they already know.

3. **Patch `connection_pool_list` to dynamically include lazy pools**. AR's snapshot semantics are deliberate; subverting them at the consumer's expense breaks isolation contracts elsewhere (savepoint enrollment, role resolution, role-specific pool lookup). The (a′) result shows the patch is also unnecessary — lazy pools enroll on first use.

4. **Test-mode `SET search_path` switching** (rejected previously in `v4-test-fixtures-compatibility.md`). Re-introduces the runtime search_path mutation v4 eliminated; undermines pool-per-tenant as the production code path.

5. **Auto-invoke `preload_test_pools!` from the railtie**. Was the safety valve for the rejected helper below. If the helper ever returns, opt-in remains the contract — `tenants_provider` may DB-query at boot or reference tenants that don't yet exist.

6. **`Apartment::Tenant.preload_test_pools!`** (retired 2026-05-19). The original contingent fix: walk `tenants_provider` and materialize pools before the first `setup_fixtures` so they would enroll in the fixture transaction. The (a′) tiebreaker in `spec/integration/v4/fixture_pool_lifecycle_spec.rb` proved lazy enrollment is reliable — rows written via a pool first materialized inside an example roll back at teardown on all matrix versions (Rails 7.2 / 8.0 / 8.1 + PG, re-verified 2026-05-19). The helper would be code shipped for a failure mode that doesn't occur. If multi-handler / `:reading` variants (workstream item 7) surface a divergence, revisit on fresh evidence.

7. **Shipping a code module for the escape hatch** (rejected 2026-05-19). The original design listed two candidate shapes: an RSpec metadata flag flipping `use_transactional_fixtures` per-example, and an `include Apartment::Test::CrossTenant` (or `Truncation`) helper. Rejected on three grounds. (a) Per-example flipping fights Rails internals — `config.use_transactional_fixtures` is global; community recipes that flip it mid-suite are version-fragile (referenced explicitly as a constraint in the panel brief). (b) An include helper would wrap Rails' supported `self.use_transactional_tests = false` primitive plus a `DatabaseCleaner` recipe — the wrapping adds API surface for downstream consumers, version-coupling, and a third place for the cleanup contract to drift from docs. (c) The three-CLI panel (codex / gemini / cursor) distributed weight across "include helper" and "docs-only"; cursor explicitly allocated 0.20 to docs-only, and the post-panel guard-scope verification eliminated the architectural concern that motivated owning the contract in code. Net: the recipe is documented in [`docs/testing.md` § Cycling pools mid-suite](../testing.md#cycling-pools-mid-suite); the gem ships no `Apartment::Test::*` module.

## Wishlist (>1 month, deferred)

Items the broader-class observation surfaced but that need their own design conversations before they enter a roadmap.

- **Parallel-spec safety hardening**. Order-dependent flakes (this doc) and concurrent flakes are different families. Process-scoping the `reset_tenant_pools!` guard is one piece; broader concurrent-fixture-tx semantics is its own investigation.
- **`PQTRANS_INERROR` recovery hooks** (member 7). The downstream `ROLLBACK` loop is evidence the variant exists. Gem-side coverage would mean an instrumented detection + recovery path, probably in `Apartment::Tenant.switch`'s ensure block.
- **Schema cache invalidation on tenant DDL** (member 8). Pinned-model joins after one tenant's DDL may resolve against stale caches. Needs adapter-specific design (PG vs MySQL diverge on cache invalidation primitives).
- **Adapter-specific savepoint behavior**. PG schema adapter under `pin_connection!` with DDL inside a tenant tx may detach the savepoint stack. Sanity check is in the existing integration spec; deeper coverage is wishlist.
- **Within-process thread / job boundaries** (member 9). Sidekiq inline, async executors, parallel_tests workers, or app-level threads that `switch` inside a worker thread may resolve pools differently from the originating thread.

## Detection primitives

Where the invariant lives in code:

- `ConnectionPool#pin_connection!` (Rails 7.1+) sets `@pinned_connection`. Apartment reads this ivar in `lib/apartment/pool_reaper.rb:164-168` via `pool_pinned?`. The `reset_tenant_pools!` guard (#2) reuses the same primitive; no new heuristics.
- `ConnectionPool#in_use?` and `Connection#open_transactions` (public API). Reaper already uses these for the in-use guard (`pool_in_use?` at `lib/apartment/pool_reaper.rb:175-182`). Available for any future lifecycle guard.
- `ActiveRecord::Base.connection_handler.connection_pool_list(:all)` — snapshot consumed by fixture machinery. Read-only from Apartment's side; do not mutate.

Across Rails 7.2 / 8.0 / 8.1 the `@pinned_connection` semantics are stable. 8.x+ may rename or refactor; the integration spec covers all matrix versions, and any divergence surfaces there.

## Cross-references

- `docs/designs/v4-test-fixtures-compatibility.md` — the `setup_shared_connection_pool` patch (PRs #379, #380). This doc generalizes that work to other lifecycle APIs.
- `docs/testing.md` — consumer-facing summary of the invariant and the available test helpers.
- `lib/apartment/pool_reaper.rb` — existing pinned and in-use guards (PRs #399, #400); the `reset_tenant_pools!` guard reuses the same primitives.
- `lib/apartment/errors.rb` — `FixtureLifecycleViolation` definition.
- `spec/integration/v4/fixture_pool_lifecycle_spec.rb` — the integration coverage that closes members 3 and 4.
- `Apartment::Tenant.with_tenants_provider` / `with_tenants` (PRs #391, #395) — block-scoped tenant-resolver overrides that consumers use to define a tenant set for a test suite without cycling pools. Adjacent but independent of this failure class; named here so future contributors don't conflate them with the docs-only escape-hatch recipe (workstream item 6).

## Origin

PR #400 closed the reaper variant of the failure class. A downstream consumer bumped to `a89aa0b` and reported a remaining order-dependent flake, bisected to a `reset_tenant_pools!` call in a `cross_tenant` shared context. Three-CLI consultation (cursor, codex, gemini) converged on the lifecycle-invariant framing and on the (a′) lazy-enrollment question as evidence-gated. The integration spec landed the evidence: (a′) is green across the matrix, so the contingent `preload_test_pools!` helper retires unbuilt.
