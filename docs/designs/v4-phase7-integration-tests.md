# Phase 7: Integration & Stress Tests

**Branch:** `man/v4-phase7-integration-tests`
**Depends on:** Phases 1-6 (all merged to `development`)
**Approach:** Single PR, all deliverables

## Motivation

Phases 1-6 built the v4 runtime: pool-per-tenant, fiber-safe CurrentAttributes, adapters, elevators, RBAC, CLI. Existing integration specs (`spec/integration/v4/`) cover tenant switching, lifecycle, excluded models, edge cases, concurrency, pool scaling, reaper eviction, LRU, request lifecycle, and RBAC. Phase 7 fills the remaining gaps identified during review.

## Gap Analysis

| Design spec deliverable | Current state | Action |
|---|---|---|
| Connection pool isolation | `stress_spec.rb:89-106` proves idempotent pool fetch. Data isolation tested via counts. | Harden: add explicit per-thread `Tenant.current` assertion + cross-tenant checkout isolation test |
| Thread safety | `stress_spec.rb:61-87` does 10x50 concurrent switches. `current_spec.rb:27-37` unit-tests thread isolation. | Harden: add barrier-synchronized `Tenant.current` checks inside threads |
| Fiber safety | Zero fiber specs anywhere. `spec/CLAUDE.md` claims coverage via CurrentAttributes but nothing proves it. | **New file:** `fiber_safety_spec.rb` |
| Pool eviction | `stress_spec.rb:189-221` (idle timeout) + `coverage_gaps_spec.rb:109-175` (LRU). | No action needed |
| Memory stability | No leak detection. 50-tenant scaling test exists but doesn't measure pool count invariants over sustained load. | **New file:** `memory_stability_spec.rb` |
| CLI smoke test | `spec/unit/cli_spec.rb` tests help output only. Phase 6 PR review flagged missing integration test. | **New file:** `cli_integration_spec.rb` |
| Appraisals + CI | Fully configured: Ruby 3.3/3.4/4.0 x Rails 7.2/8.0/8.1 x PG 16+18/MySQL 8.4/SQLite3. | No action needed |
| Request lifecycle | Complete in `request_lifecycle_spec.rb` (elevator->switch->response->cleanup). | No action needed |

## File Structure

No new directories. All new files live in `spec/integration/v4/` (flat, consistent with existing layout and activerecord-tenanted's pattern).

```
spec/integration/v4/
  fiber_safety_spec.rb          # NEW
  memory_stability_spec.rb      # NEW
  cli_integration_spec.rb       # NEW
  stress_spec.rb                # MODIFIED (2 new `it` blocks)
```

## Spec Designs

### 1. `fiber_safety_spec.rb`

**Proves:** `Apartment::Current` (backed by `ActiveSupport::CurrentAttributes` / `IsolatedExecutionState`) isolates tenant state across fibers.

**Tests:**

- **Basic fiber isolation**: Parent fiber sets tenant A, spawns child fiber that sets tenant B, parent still reads tenant A after child completes. Mirror of `current_spec.rb:27-37` thread test but with `Fiber.new`.
- **Nested fiber switching**: Fiber does `Tenant.switch('x') { Fiber.yield }`, resumes, tenant still correct after yield/resume cycle.
- **Switch block + fiber interaction**: Outer `switch('a')` block, inner fiber does `switch('b')`, outer block still in tenant A after fiber returns.
- **Fiber scheduler integration** (conditional, `skip` unless `Fiber.respond_to?(:scheduler)` and Ruby >= 3.1): Use `Fiber.schedule` under a basic scheduler to prove async fiber dispatch doesn't leak tenant state.

**Engine scope:** All engines (SQLite, PG, MySQL). Fiber isolation is engine-agnostic; it's a Ruby/Rails runtime concern.

**Estimated size:** ~80-100 lines.

### 2. `memory_stability_spec.rb`

**Proves:** Pool count stays bounded under sustained switching. No connection/pool leaks when `max_total_connections` is configured and the reaper is active.

**Tests:**

- **Pool count stays bounded**: Configure `max_total_connections = 5`, create 20 tenants, switch through all 20 in a loop (3 full cycles). After each cycle, invoke `pool_reaper.run_cycle` (public API; `coverage_gaps_spec.rb:166` uses `send(:reap)` which is stale — that spec should be updated as a drive-by), then assert `pool_manager.stats[:total_pools] <= max_total_connections`.
- **Repeated create/drop doesn't leak pools**: Create tenant, switch into it, drop it — repeat 20 times. Assert pool count at end equals pool count at start (plus/minus 1 for default pool). Proves drop path cleans up pool entries.
- **Sustained switching without pool growth**: Configure generous `max_total_connections` (no eviction pressure), create 5 tenants, do 200 round-robin switches. Assert final pool count == 5. No phantom pools from race conditions or double-registration.

**Engine scope:** PG and MySQL only. SQLite skipped (single-writer lock under concurrent access makes pool-per-tenant less meaningful).

**Design decision — no RSS/ObjectSpace measurement:** Flaky across Ruby versions and GC timing. Pool count invariant is the meaningful signal; if pools don't leak, connections don't leak.

**Estimated size:** ~100-120 lines.

### 3. `cli_integration_spec.rb`

**Proves:** Thor CLI commands perform real tenant operations against a live database.

**Tests:**

- **`tenants list`**: Create 3 tenants via adapter, invoke `Apartment::CLI::Tenants.new.invoke(:list)`, capture stdout. Assert all 3 names appear.
- **`tenants create`**: Invoke `Apartment::CLI::Tenants.new.invoke(:create, ['cli_tenant'])`, verify tenant exists by switching into it and executing a query.
- **`tenants drop`**: Create tenant via adapter, invoke `Apartment::CLI::Tenants.new.invoke(:drop, ['cli_tenant'], force: true)` (or set `ENV['APARTMENT_FORCE'] = '1'`) to bypass the confirmation prompt in non-interactive test runs. Verify adapter raises `TenantNotFound` on subsequent drop attempt.
- **`pool stats`**: Access a tenant to populate a pool, invoke `Apartment::CLI::Pool.new.invoke(:stats)`, capture stdout and assert output includes `total_pools` and tenant name.

**Not tested here:** `migrations run` / `seeds load` — covered by `migrator_integration_spec.rb`. CLI is a thin Thor wrapper; proving CRUD + stats wiring is sufficient.

**Engine scope:** All engines.

**Estimated size:** ~80-100 lines.

### 4. Hardening `stress_spec.rb`

**What changes:** Additive only: two new `it` blocks in the existing `concurrent switching` context. Existing examples are not changed.

**Test A — Explicit tenant identity per thread:**
5 threads, each assigned a specific tenant. `CyclicBarrier` synchronizes entry. Inside switch block, assert both `Apartment::Tenant.current` and `Apartment::Current.tenant` equal the assigned tenant (locks the alias relationship). Results collected in `Concurrent::Map`, assertions on main thread.

**Why:** Existing test proves correct data distribution (500 writes across tenants) but doesn't prove each thread sees the correct tenant identity. A bug where `Tenant.current` returns stale state but pool resolution works correctly would pass the existing test but fail this one.

**Test B — Cross-tenant connection checkout isolation:**
2 threads with dedicated tenants (`tenant_a`, `tenant_b`). Barrier ensures both are inside switch blocks simultaneously. Each thread inserts a row tagged with its thread index into the shared `widgets` table (which exists per-tenant as a separate schema/database/file), then reads back `Widget.pluck(:name)`. Assert: thread A's read returns only `['thread_a']`, thread B's read returns only `['thread_b']`. Per-engine isolation mechanism (PG schema, MySQL database, SQLite file) means "only its own rows" is enforced by the adapter's tenant boundary, not by a `WHERE` clause. Proves no connection was checked out from the wrong pool mid-switch.

**Why:** Existing concurrent test uses `tenants.sample` (random selection), which proves no errors and correct totals but can't assert per-thread isolation. Dedicated tenants with barrier makes the isolation assertion precise.

**Estimated size:** ~60-70 lines added.

## Implementation Order

All 5 items are independent. Recommended order for implementation (not sub-phases; all in one PR):

1. `fiber_safety_spec.rb` — smallest, most self-contained, proves a v4 value proposition
2. `memory_stability_spec.rb` — depends on understanding reaper internals (already proven in existing specs)
3. `stress_spec.rb` hardening — additive to existing file, low risk
4. `cli_integration_spec.rb` — depends on understanding Phase 6 Thor structure
5. Run full suite across all engines, verify CI green

## Test Execution

```bash
# New specs individually
bundle exec appraisal rails-8.1-sqlite3 rspec spec/integration/v4/fiber_safety_spec.rb
DATABASE_ENGINE=postgresql bundle exec appraisal rails-8.1-postgresql rspec spec/integration/v4/memory_stability_spec.rb
bundle exec appraisal rails-8.1-sqlite3 rspec spec/integration/v4/cli_integration_spec.rb

# Full integration suite (all engines)
bundle exec appraisal rails-8.1-sqlite3 rspec spec/integration/v4/
DATABASE_ENGINE=postgresql bundle exec appraisal rails-8.1-postgresql rspec spec/integration/v4/
DATABASE_ENGINE=mysql bundle exec appraisal rails-8.1-mysql2 rspec spec/integration/v4/
```

## Success Criteria

- All new specs pass on PG, MySQL, and SQLite (where applicable)
- Existing examples unchanged and still passing
- CI matrix green (no new failures)
- Optional manual gate: `COVERAGE=1` run shows no coverage regression (not part of CI; run locally before merge)

## Drive-by Fix

`coverage_gaps_spec.rb:166` uses `Apartment.pool_reaper.send(:reap)` — update to `Apartment.pool_reaper.run_cycle` (public API) while we're in the file neighborhood.
