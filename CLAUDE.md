# CLAUDE.md - Apartment

**Gem Name**: `ros-apartment`
**Maintained by**: CampusESP
**Active work**: v4 rewrite (phased, PR-per-sub-phase off `main`)

## Design & Plan Documents

Planning artifacts live in `docs/` with no date prefixes (git handles temporal tracking):

- `docs/designs/<feature>.md` — Design specs (what and why). Living docs, one per feature, updated in place.
- `docs/plans/<feature>/` — Implementation plans (how and in what order). Can have multiple files for phased plans.

Do NOT use `docs/superpowers/specs/` or `docs/superpowers/plans/` — those are plugin defaults that we override with the paths above.

**Key documents:**
- `docs/designs/apartment-v4.md` — v4 design spec
- `docs/designs/v4-railtie-test-infra.md` — Railtie + test infrastructure design
- `docs/designs/elevator-tenant-validation.md` — Elevator tenant validation + missing-tenant fail-safe (shipped; see Key Patterns)
- `docs/plans/apartment-v4/phase-2-adapters.md` — Current phase plan (includes deferred review items)

## Where to Start

1. **README.md** - Installation, basic usage, configuration options
2. **docs/architecture.md** - Core design decisions and WHY they were made (v3)
3. **docs/designs/apartment-v4.md** - v4 architecture and motivation
4. **lib/apartment/CLAUDE.md** - Implementation file guide
5. **spec/CLAUDE.md** - Test organization and patterns

## Commands

```bash
# Unit tests (no database required)
bundle exec rspec spec/unit/

# Unit tests across Rails versions
bundle exec appraisal install                              # first time only
bundle exec appraisal rails-8.1-sqlite3 rspec spec/unit/   # single version
bundle exec appraisal rspec spec/unit/                     # all versions

# v4 integration tests (requires real databases)
bundle exec appraisal rails-8.1-sqlite3 rspec spec/integration/v4/                        # SQLite
DATABASE_ENGINE=postgresql bundle exec appraisal rails-8.1-postgresql rspec spec/integration/v4/  # PostgreSQL
DATABASE_ENGINE=mysql bundle exec appraisal rails-8.1-mysql2 rspec spec/integration/v4/          # MySQL

# Lint
bundle exec rubocop

# Build gem
gem build ros-apartment.gemspec

# Coverage report (opt-in)
COVERAGE=1 bundle exec rspec spec/unit/

# Test profiling
FPROF=1 bundle exec appraisal rails-8.1-sqlite3 rspec spec/integration/v4/
EVENT_PROF=sql.active_record bundle exec appraisal rails-8.1-sqlite3 rspec spec/integration/v4/

# Request lifecycle tests (requires PostgreSQL)
DATABASE_ENGINE=postgresql bundle exec appraisal rails-8.1-postgresql rspec spec/integration/v4/request_lifecycle_spec.rb

# RBAC integration tests (requires provisioned PG/MySQL roles; see docs/designs/v4-phase5.2-rbac-integration-tests.md)
DATABASE_ENGINE=postgresql bundle exec appraisal rails-8.1-postgresql rspec spec/integration/v4/ --tag rbac
DATABASE_ENGINE=mysql bundle exec appraisal rails-8.1-mysql2 rspec spec/integration/v4/ --tag rbac
```

**CI matrix**: Ruby 3.3/3.4/4.0 × Rails 7.2/8.0/8.1/main × PG 16+18, MySQL 8.4, SQLite3. Rails main is a canary (`continue-on-error`). See `.github/workflows/ci.yml`.

## Core Concepts

**Multi-tenancy via database isolation**: One app, many customers, data fully separated.
- **PostgreSQL (schemas)**: Namespaces in single DB. Fast (<1ms switch), scales to 100+ tenants.
- **MySQL (databases)**: Separate DB per tenant. Complete isolation, slower switching.
- **Elevators**: Rack middleware extracts tenant from request. Auto-inserted after `ActionDispatch::Callbacks` (before sessions/auth).
- **Pinned models**: Global tables declared with `Apartment::Model` + `pin_tenant`. Bypasses tenant routing. Use `has_many :through`, not HABTM. Replaces `excluded_models` (deprecated in v4).

See `docs/architecture.md` for v3 design decisions, `docs/adapters.md` for strategy trade-offs, `docs/elevators.md` for middleware rationale.

## Key Patterns

- **Block-based switching**: Always prefer `switch(tenant) { ... }` over `switch!`. Ensure block guarantees cleanup on exceptions.
- **Adapter pattern**: Abstract base class with database-specific subclasses. Unified API hides DB differences.
- **Callbacks**: `ActiveSupport::Callbacks` on `:create` and `:switch` for logging/notification hooks.
- **Dynamic tenant discovery**: `tenants_provider` is a callable (proc/lambda) that queries the database at runtime.
- **Tenant name validation**: `TenantNameValidator` does pure in-memory format checks (no DB queries). Enforced in `AbstractAdapter#create` and `ConnectionHandling#connection_pool`. Engine-specific rules for PG identifiers, MySQL names, SQLite paths.
- **Elevator tenant validation + missing-tenant fail-safe** (design: `docs/designs/elevator-tenant-validation.md`): distinct from name-format validation above. `Apartment::TenantValidator` is a process-local memoized set of valid tenant names; the elevator returns a 404 for an unknown tenant instead of a deep 500. The **request-path fail-safe is shipped** across every catalog-backed engine — PG schema-per-tenant, PG database-per-tenant, MySQL/Trilogy. A tenant dropped by another process self-heals to a 404 within one request per worker: the elevator wraps the switch, and on an adapter-declared error class a strict classifier (`tenant_container_gone?` → `container_error?` + an authoritative `to_regnamespace`/`pg_database`/`information_schema` probe) confirms the drop, evicts the stale positive, and 404s; anything it cannot positively classify re-raises. SQLite is a **reasoned exclusion** (no sound "container gone" signal — a dropped file auto-recreates empty), documented in the adapter, a unit guard, and the design doc.
  - **Remaining (deferred on purpose):** only the opt-in cross-process **transport seam** — the proactive pub/sub path that would propagate creates/drops without waiting for a request to trip the fail-safe (closing create-latency and the residual warm-pool / SQLite cases). The reactive fail-safe is the evidence base for whether the proactive seam earns a shipped dependency, and no adopter has yet reported a gap it would close. The escape hatch (a custom `tenant_validator` backed by a dedicated, un-namespaced store) remains available in the meantime.
- **Tenant-aware caching + context guards** (design: `docs/designs/tenant-aware-caching.md`, guide: `docs/caching.md`): cache splits into **routed** (per-tenant, key MUST carry the tenant) vs **pinned** (global, key MUST NOT) — the same distinction `pin_tenant` draws for models. Non-request code (jobs, rake, cable) that forgets to switch silently writes routed data into the default keyspace. Guard it with `Apartment::Tenant.require_tenant!` (real, non-default) / `require_default_tenant!` (default/pinned), predicates `in_tenant?` / `in_default_tenant?`, `with_default_tenant { }`, and `cache_namespace` (fail-closed namespace proc). The two axes: **explicitness** (`tenant_switched?` / `assert_tenant_switched!`, raw `Current.tenant`, test discipline — renamed from `inside_tenant?` / `assert_inside_tenant!`) vs **identity** (the `in_`/`require_` family, effective `Tenant.current`). Use the two-store cache recipe so pinned keys don't fragment across tenant keyspaces. Apartment owns the discipline, not the store.

## Code style

Prefer **SOLID** and explicit APIs over **metaprogramming** unless there is a concrete reason to break SOLID. Metaprogramming can be concise but is easy to misuse because it is powerful (e.g. ad hoc `instance_variable_*` on arbitrary classes). When state or behavior must live on models, use a concern and named public class methods; keep ivar details encapsulated inside that layer (adapters should not reach into AR classes). See `lib/apartment/CLAUDE.md` (`concerns/model.rb`) for pinned-model APIs (`apartment_pinned?`, `apartment_explicit_table_name?`, `apartment_mark_processed!`, `apartment_restore!`, etc.).

## Testing

```bash
bundle exec rspec spec/unit/                    # v4 unit tests
bundle exec appraisal rspec spec/unit/          # across all Rails versions
```

v4 unit tests are in `spec/unit/` and require no database. See `spec/CLAUDE.md` for test organization.

## v4 Rewrite

**Design spec**: `docs/designs/apartment-v4.md`

**Major changes**: Pool-per-tenant (vs thread-local switching), fiber-safe via `CurrentAttributes`, immutable connection config per pool, `Config#freeze!` after validation

**Why v4**: Fixes thread-local tenant leakage (e.g., ActionCable shared thread pool bugs). Adds fiber safety, PgBouncer/RDS Proxy transaction mode compatibility, and a simpler mental model.

**Status**: Phases 1, 2.1, 2.2, 2.3 merged. Phase 2.4 merged. Railtie + test infrastructure complete. See `docs/plans/apartment-v4/` for full plan.

## Gotchas

- **v3 removal**: v3 files were deleted as of Phase 2.5. `lib/apartment/` contains only v4 code. The v3 elevators in `lib/apartment/elevators/` remain Zeitwerk-ignored until Phase 3 replaces them.
- **Frozen config**: `Apartment.config` is frozen after `Apartment.configure`. Tests that need different config values must call `Apartment.configure` again (not stub the frozen object).
- **Monotonic clock**: `PoolManager` uses `Process.clock_gettime(Process::CLOCK_MONOTONIC)` for timestamps, not `Time.now`. Stats return `seconds_idle` (duration), not wall-clock times.
- **schema_load_strategy**: Defaults to `nil` (no schema loading on create). Set to `:schema_rb` or `:sql` to auto-load schema into new tenants.
- **v4 Railtie**: `lib/apartment/railtie.rb` is now v4. It auto-wires `activate!`, `init`, middleware, and rake tasks after `Apartment.configure` runs. No manual middleware insertion needed.
- **`connects_to` edge case**: Models (or abstract base classes) that use `connects_to` to point at a separate database need `pin_tenant` to prevent Apartment from creating tenant pools for them. The common pattern of `ApplicationRecord` using `connects_to` with multiple roles (writing/reading) on the same database works correctly without any special handling.
- **AR's connection registry is not thread-safe** (design: `docs/designs/ar-connection-registry-thread-safety.md`): `ActiveRecord::ConnectionAdapters::PoolManager` — Rails' registry, not Apartment's same-named class — stores pools in a plain nested Hash with no synchronization, because Rails only writes it at boot. Pool-per-tenant writes it for the life of the process, so a cold tenant switch could add a shard key while another thread was iterating, and MRI's iteration guard (per-Hash, not per-thread) failed **the switch** with `RuntimeError: can't add a new key into hash during iteration`. The readers are Rails' own, all via `ConnectionHandler#each_connection_pool`: `QueryCache.run` (every executor run — the start of every request/job), `ConnectionPool::ExecutorHooks.complete` (every completion), `clear_query_caches_for_current_thread` (after writes), `all_open_transactions`, and the `clear_*`/`flush_*` family. **Not** AR's `ConnectionPool::Reaper`, which keeps a private mutex-protected `WeakRef` list and never reads the registry (verified on 7.2/8.0/8.1) — target the real readers when reasoning about synchronization. `Apartment::Patches::ConnectionRegistry` (applied by `activate!`) serializes all eight `PoolManager` accessors on one process-wide `Monitor` and the handler's `set_pool_manager` upsert (kept `private`); `each_pool_config` snapshots under the lock and yields outside it, so the lock is never held across a caller's block (Rails disconnects pools inside those blocks) — `SYNC` is a leaf lock, which is the whole deadlock argument. On upstream shape drift it **fails closed**: `method_defined?` resolution (so a method merely moved to a superclass still counts) and a raise at `activate!` when one is genuinely gone; only an added-but-unguarded accessor warns. Apartment's own create locks do NOT cover this: they serialize writers against writers, and the race is writer-versus-reader.
- **Pinned table qualification is assignment, never `table_name_prefix`** (design: `docs/designs/v4-shared-pinned-connections.md`): `compute_table_name` consults `full_table_name_prefix` **only on its `base_class?` branch**, so prefix-based qualification cannot reach a class that is not its own `base_class` (it gets `base_class.table_name` verbatim) nor an engine-namespaced model (`full_table_name_prefix` prefers the module parent), and overwriting the prefix drops one the app set. Each case leaves the model resolving through `search_path` to the *tenant's* table with nothing raised. `qualify_pinned_table_name` therefore reads `table_name` — letting Rails compose prefix, suffix and nesting — then assigns the qualified result. **The one exception is an abstract pinned base**, which has no table of its own and sets `table_name_prefix` as a *broadcast* to descendants that are never individually registered. Three further traps, each with a regression test: (1) `apartment_explicit_table_name?` answers exactly one question — "would convention rebuild this cached name?" — and that answer legitimately feeds three decisions: which restore strategy to record, whether a subclass shares its base's table (`inherits_pinned_table?`), and whether an unregistered descendant declared its own (the boot warning). What it must **not** do is select the qualification *strategy*, assignment vs `table_name_prefix`; that misuse is what made the subclass case silent; (2) Rails never invalidates a **descendant's** `@table_name` memo when an ancestor changes, so qualification and teardown bracket their mutation (collect inheriting descendants *before*, `reset_table_name` them *after*, ancestor-first) — and the collection predicate mirrors `reset_table_name`, not `compute_table_name`, because the two disagree for a class whose superclass is abstract; (3) `pin_tenant` is idempotent **per class**, not per hierarchy, so a subclass declaring its own table registers and qualifies on its own merits. `verify_pinned_qualification!` then proves the outcome: the registered model **raises** if unqualified (complete check), its descendants **warn** (`descendants` is complete only under eager loading).
- **All tenant DDL runs on `migration_role`, creation included** (design: `docs/designs/v4-phase5-rbac-roles-schema-cache.md`): the create-time grants Apartment installs for `app_role` end with `ALTER DEFAULT PRIVILEGES`, and PostgreSQL scopes that rule to the role that **executed** it, never to the role named in the GRANT. So `Tenant.create` and the Migrator have to share one role or every table a later migration adds falls outside the rule, with nothing raised until an ordinary query touches it. `AbstractAdapter#run_tenant_ddl` brackets `create_tenant`, `grant_tenant_privileges`, and `import_schema` in `MigrationRole.wrap` for that reason. Three details are load-bearing: the wrap covers all three steps, not just the grants, because the container is owned by its creator (and `ALTER` needs ownership) while `grant_privileges` gives the app role USAGE plus DML but never CREATE, so an import on the writing role could not add tables to a container it does not own; seeding stays **outside** the wrap, since rows carry no ownership; and cleanup releases its own lease, then uses `Apartment.deregister_shard` on this tenant's key alone **only if the pool is not in use** (`Apartment.pool_in_use?`, shared with `PoolReaper`) — `PoolManager#evict_by_role` would drop other tenants' pools, and the same key is what a concurrent migration of *this* tenant leases, so an unguarded discard disconnects that migration; one idle pool left for the reaper is the cheaper outcome. The design doc originally called this invariant self-enforcing and left the create-time role to the adopter — that reasoning holds for one role in isolation and breaks across the pair.
- **Tenant creation suppresses the pending-migration check**: `create`'s schema import and seeding switch into the container being built, and resolving that pool is where `ConnectionHandling#check_pending_migrations?` runs — against a tenant that has of course run no migration, so `create` raised `PendingMigrationError` on the thing it was creating. `AbstractAdapter#suppressing_pending_migration_check` brackets the create body with `Current.migrating`, the same flag `Migrator` uses, and **restores the previous value** rather than clearing it so a create nested inside a migration does not disarm the migration. Three facts make this behave unintuitively and are each pinned by a test: a `Tenant.switch` alone does **not** trip the check (the pool is resolved by the first query, so a no-op seed file hides the bug entirely); the pool create leaves behind was built under suppression and is therefore never re-checked while it stays warm — deliberate, since the check is a development convenience and a tenant created moments ago is where the warning is least useful; and the check is inert across the whole spec suite because `spec/support/rails_stub.rb` returns a `StringInquirer`, whose `local?` asks whether the env is *named* "local" (see `spec/CLAUDE.md`), which is why no spec proved it fires and most specs disable it defensively.
- **`Model.sequence_name` memoization**: Rails memoizes it per model class, process-wide, resolved schema-qualified (via `pg_get_serial_sequence`, which always fully qualifies) on whichever tenant's connection touched it first. `Apartment::Patches::PostgresqlSequenceName` (registered at gem load in `lib/apartment.rb`, not in `activate!`, because memoization can fire during boot) strips it back to an unqualified name so prefetched ids — e.g. `activerecord-import`'s literal `nextval(Model.sequence_name)` — come from the current tenant's sequence. Two asymmetries are load-bearing, each with a regression test: the strip is **unconditional** for routed tables (stripping only the pool's *own* schema would pin a `search_path` fallback schema into the memo for every tenant when one tenant is un-migrated), and **skipped entirely** for schema-qualified table names, i.e. pinned models, whose sequence is correct only *because* it stays qualified to the default tenant. Nothing inside the gem calls `sequence_name` — host-app gems do — so don't delete the patch as "unused"; that is exactly how the v3 original was lost in #356.
