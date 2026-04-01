# v4 Migrations — Design Spec

## Overview

This spec covers the Migrator, schema dumper patch, schema cache generation, and rake/Thor task integration for Apartment v4. The Migrator orchestrates ActiveRecord migrations across all tenants with optional thread-based parallelism.

**Primary goal:** `Apartment::Migrator` migrates the primary database and all tenant schemas/databases, with per-tenant result tracking and thread parallelism.

**Secondary goals:**
- Fix Rails 8.1 `public.` prefix regression in `schema.rb` dumps
- Support both `schema.rb` and `structure.sql` as schema formats
- Provide schema cache generation (single canonical or per-tenant)
- Wire into `db:migrate:DBNAME` for zero-config defaults while keeping `apartment:migrate` for full control

## Context & Motivation

### Why Tenant.switch, not standalone pools?

The original design proposed a standalone `PoolManager` with ephemeral per-tenant pools. During implementation, we discovered that Rails' migration machinery hardcodes `DatabaseTasks.migration_connection` → `ActiveRecord::Base.lease_connection`, bypassing any standalone pool. Three approaches were tried (standalone pools, handler registration with unique `owner_name:`, thread-local `ConnectionHandler` swaps) — all failed due to this coupling.

v4's `ConnectionHandling` patch already solves the routing problem: `Tenant.switch` sets `Current.tenant`, and the patch intercepts `AR::Base.connection_pool` to return the tenant's pool. Since `AR::Base.lease_connection` goes through `connection_pool`, Rails' migration runner automatically uses the correct tenant connection. No standalone pools, handler swaps, or monkey-patches needed.

**RBAC credential separation** (`migration_db_config`) is deferred to Phase 5. The challenge: `Tenant.switch` uses runtime pools with `app_user` credentials, but DDL operations need `db_manager`. Phase 5 will address this by allowing the adapter to resolve credentials from a database.yml config name (e.g., `:db_manager`) during migration context, following the pattern established in CampusESP's `database.yml` where `db_manager` is a separate config with elevated credentials.

### Why threads only?

Migrations are IO-bound (DDL statements sent to PostgreSQL, waiting for responses). Ruby releases the GVL during IO syscalls, so threads achieve real parallelism for this workload. CampusESP's `release.rb` already validates this pattern at scale with `Parallel.each(..., in_threads: 8)` across 500+ schemas on CodeBuild (8 vCPU, 16 GiB).

Process-based parallelism (`fork`) is dropped from the design:
- `fork` + ActiveRecord connections is a known footgun (pools don't survive fork)
- Memory doubles per worker (CoW degrades as Ruby's GC touches pages)
- Result marshaling across processes requires pipes/sockets
- Ractors are incompatible with ActiveRecord's connection model (byroot, Feb 2025)
- Fiber schedulers add complexity without benefit when parallelism is across tenants (each thread's work is inherently serial)

### Why no per-schema advisory locks?

Rails' advisory lock for migrations uses a single database-scoped lock ID. Per-schema advisory locks (incorporating `current_schema` into the lock ID) were proposed in [rails/rails#43500](https://github.com/rails/rails/pull/43500) but rejected by Rails core. The reasons apply to Apartment:

1. **Incomplete guarantee.** Advisory locks scoped to a schema don't protect against cross-schema DDL. A migration that references `public.shared_table` is not covered by a lock on `acme`. The lock's scope doesn't match the operation's scope (matthewd, Rails core).
2. **Operational concern, not a locking concern.** Duplicate Migrator invocations are prevented by deploy pipeline serialization (e.g., CodePipeline), not by in-process locks.
3. **Recoverable failure mode.** If two processes do race, `PG::UniqueViolation` on DDL is a clear error, not silent data corruption.
4. **False confidence.** Users who see "advisory lock acquired" may assume full isolation, when they don't have it.

The v4 Migrator disables advisory locks during parallel migration and documents the operational requirement: only one Migrator should run at a time per database. The `schema_migrations` table serves as the last-resort idempotency check.

See: [rails-on-services/apartment#298](https://github.com/rails-on-services/apartment/issues/298), [rails/rails#43500](https://github.com/rails/rails/pull/43500#issuecomment-2447817077)

## Migrator Architecture

### `Apartment::Migrator`

Orchestrator that delegates to `Tenant.switch` for connection routing and Rails' standard migration machinery for DDL execution.

**Constructor:**

```ruby
Apartment::Migrator.new(
  threads: 8,                          # 0 = sequential (default)
)
```

- `threads`: concurrency level. `0` means sequential (safe default for development, CI debugging).

**Execution flow:**

```
Migrator#run
  ├── Phase 1: Migrate primary database (blocking)
  │     Uses AR::Base.connection_pool directly (default connection)
  │     Checks for pending migrations; skips if up-to-date
  │     Aborts entire run on failure (tenants are never touched)
  ├── Phase 2: Migrate tenants (parallel or sequential)
  │     ├── Resolve tenants from tenants_provider
  │     ├── For each tenant:
  │     │     ├── Tenant.switch(tenant) — ConnectionHandling patch routes AR::Base to tenant's pool
  │     │     ├── Disable advisory locks on leased connection
  │     │     ├── AR::Base.connection_pool.migration_context.migrate
  │     │     ├── Record Result (success/failure + timing)
  │     │     └── Tenant.switch ensure block restores previous tenant
  │     └── Collect Results
  └── Return MigrationRun (summary + per-tenant results)
```

Schema dump (Phase 3) is handled by the rake task after `Migrator#run` returns, respecting `ActiveRecord.dump_schema_after_migration`. Schema cache generation (Phase 4) is deferred.

### Connection Routing

The Migrator does not create its own pools. For each tenant, `Tenant.switch` sets `Current.tenant`, and the `ConnectionHandling` patch intercepts `AR::Base.connection_pool` to return the tenant's pool from v4's runtime `PoolManager`. Rails' migration runner calls `DatabaseTasks.migration_connection` → `AR::Base.lease_connection` → `connection_pool.lease_connection`, which resolves to the tenant's pool automatically.

This means migrations use the same pools (and credentials) as the runtime application. RBAC credential separation (`migration_db_config`) — where DDL runs with `db_manager` credentials instead of `app_user` — is deferred to Phase 5. The design point: the adapter's connection config resolution could accept an optional credential overlay from a database.yml entry (e.g., `:db_manager`), following CampusESP's pattern where `db_manager` is a separate config with elevated credentials.

### Thread Coordination

Work-stealing via `Queue` (stdlib, thread-safe). Each thread pops a tenant from the queue, migrates it, records the result, and pops the next. Results collected in a `Concurrent::Array` (requires `concurrent-ruby`, already a v4 dependency via `PoolManager`). No shared mutable state beyond these two thread-safe structures.

```ruby
work_queue = Queue.new
tenants.each { |t| work_queue << t }
threads.times { work_queue << :done }     # poison pills

results = Concurrent::Array.new

workers = threads.times.map do
  Thread.new do
    while (tenant = work_queue.pop) != :done
      result = migrate_tenant(tenant)
      results << result
    end
  end
end

workers.each(&:join)
```

## Result Tracking

### `Apartment::Migrator::Result`

Value object per tenant migration, using `Data.define` (Ruby 3.2+, immutable):

```ruby
Result = Data.define(
  :tenant,           # String — tenant name
  :status,           # Symbol — :success, :failed, :skipped
  :duration,         # Float — seconds (monotonic clock)
  :error,            # Exception or nil
  :versions_run      # Array<Integer> — migration versions applied
)
```

- `:skipped` for tenants already up-to-date (no pending migrations)
- `versions_run` gives visibility into what changed per tenant

### `Apartment::Migrator::MigrationRun`

Aggregate returned by `Migrator#run`:

```ruby
MigrationRun = Data.define(
  :results,          # Array<Result>
  :total_duration,   # Float — wall clock for entire run
  :threads           # Integer — concurrency used
) do
  def succeeded = results.select { _1.status == :success }
  def failed    = results.select { _1.status == :failed }
  def skipped   = results.select { _1.status == :skipped }
  def success?  = failed.empty?
end
```

**Reporting:** `MigrationRun#summary` returns a formatted string for logging. The Migrator emits `ActiveSupport::Notifications` events (`migrate_tenant.apartment`) per tenant, following v4's `verb.namespace` convention (e.g., `switch.apartment`, `create.apartment`).

**Failure handling:** A failed tenant does not halt the run. All tenants are attempted. The caller inspects `migration_run.success?` and decides the response (raise, log, alert).

## Schema Dumper Patch

### Problem

Rails 8.1 added schema-qualified table names to `schema.rb` output (e.g., `create_table "public.users"`). When loaded into a tenant schema, tables land in `public` instead of the tenant's schema.

### Solution

Patch `ActiveRecord::SchemaDumper` to strip the `public.` prefix during dump. Applied conditionally (Rails >= 8.1 only). The dumped `schema.rb` is schema-agnostic — works for both public and tenant schemas.

`structure.sql` behavior depends on `pg_dump` flags. Rails' `db:structure:dump` may produce schema-qualified DDL (e.g., `CREATE TABLE public.users`) depending on the Rails version and `pg_dump` configuration. If Rails 8.1 changed `schema.rb` output to include `public.` prefixes, the `structure.sql` dump should also be verified. The Migrator should control or document the expected `pg_dump` flags to ensure clean output. If `structure.sql` contains `public.` prefixes, the same stripping logic may need to apply during schema load (but not during dump, since the dump reflects the actual database state).

### `include_schemas_in_dump`

This option already exists in `PostgresqlConfig` (accessed via `configure_postgres`). It specifies non-public schemas whose tables should retain their schema prefix in `schema.rb` dumps (e.g., `%w[ext shared]`). Tables in `public` always get their prefix stripped by the patch.

```ruby
Apartment.configure do |c|
  c.configure_postgres do |pg|
    pg.include_schemas_in_dump = %w[ext shared]
  end
end
```

Default: `[]` (strip all `public.` prefixes; no non-public schemas retained).

## Schema Cache

### Default: Single Canonical Cache

All tenants share the canonical public schema cache. After the Migrator completes:
1. Public schema was migrated first
2. Schema dump runs against public (produces `schema.rb` or `structure.sql`)
3. `db:schema:cache:dump` produces one `schema_cache.yml`
4. All tenants use this file at runtime (shared schema structure)

### Optional: Per-Tenant Cache

`schema_cache_per_tenant: true` generates a cache file per tenant after migrating it, stored as `db/schema_cache_<tenant>.yml`. Use case: tenants on different shards that may diverge in schema over time.

When `schema_cache_per_tenant` is enabled, `public.` prefixes are retained in per-tenant cache files (each cache reflects its actual schema context). Prefix stripping is only needed for the shared canonical mode.

| Mode | Schema dump | Schema cache | `public.` prefix |
|------|------------|--------------|------------------|
| Default (shared) | Single file, schema-agnostic | Single `schema_cache.yml` from public | Stripped |
| Per-tenant | Single file, schema-agnostic | Per-tenant `schema_cache_<tenant>.yml` | Retained in cache |

Schema cache generation is opt-in. The Migrator does not generate caches by default; callers (rake tasks, `release.rb`) control when caching runs.

## Task Integration

### Three layers (most specific to least)

1. **Thor CLI** (primary, most options): `apartment migrate --threads 8 --db-config db_manager` — Phase 6 deliverable, not implemented in Phase 4
2. **`apartment:migrate` rake** (thin wrapper): delegates to Migrator with config defaults, supports `VERSION=` env var
3. **`db:migrate:DBNAME` enhancement** (Rails-native hook): when Apartment is loaded, enhances the task to also run `apartment:migrate` after the base migration

Thor commands are the canonical interface (Phase 6). Rake tasks are convenience wrappers. The `db:migrate:DBNAME` hook provides zero-config defaults.

### Rake tasks (Phase 4)

```
apartment:migrate                       # uses config defaults
apartment:migrate VERSION=20260401      # specific version
apartment:rollback[2]                   # rollback 2 steps (matches existing v4.rake argument syntax)
```

These delegate to the Migrator. The existing v4.rake tasks are updated to wire through the Migrator instead of direct adapter calls. The rake task checks `ActiveRecord.dump_schema_after_migration` before invoking the Migrator's schema dump phase (the module-level accessor, not the removed `ActiveRecord::Base` method; see [ros-apartment#342](https://github.com/rails-on-services/apartment/pull/342)).

### `db:migrate:DBNAME` enhancement

When Apartment is loaded, the Railtie enhances `db:migrate:primary` (or whatever the primary database config is named) to also invoke `apartment:migrate`. This provides Rails-native compatibility without requiring users to know about Apartment's task namespace.

The enhancement must not interfere with other database configs (e.g., `db:migrate:ddl_workspace`).

**Idempotency:** If `db:migrate:primary` triggers `apartment:migrate`, and the user then runs `apartment:migrate` directly, the Migrator checks for pending migrations per tenant. Tenants already up-to-date return `:skipped`. Phase 1 (primary database migration) also checks for pending migrations before executing. Running the Migrator twice is safe and fast.

### Composability with existing Thor tasks

CampusESP uses `schema:pristine` and `schema:baseline` Thor tasks for schema management. These operate on a separate `ddl_workspace` database config and use `db:migrate:ddl_workspace`. The Migrator's `db:migrate:primary` enhancement is scoped to the primary config only; these tasks are unaffected.

The baseline loader migration uses `connection_db_config` to resolve credentials for `psql`. Phase 5 will add `migration_db_config` support so the Migrator can use `db_manager` credentials for DDL operations, matching the pattern these Thor tasks already use.

## Configuration

New config options added in Phase 4:

```ruby
Apartment.configure do |c|
  # Migrator
  c.parallel_migration_threads = 8      # Integer — 0 = sequential (default)

  # PostgreSQL-specific (already exists in PostgresqlConfig)
  c.configure_postgres do |pg|
    pg.include_schemas_in_dump = %w[ext shared]  # schemas that retain prefix in schema.rb dumps
  end
end
```

**Removed from Config:** `parallel_strategy` and `VALID_PARALLEL_STRATEGIES` are removed. The `parallel_migration_threads` attribute (already exists, default `0`) is the sole parallelism control. Threads are the only parallelism primitive.

**Deferred to Phase 5:**
- `migration_db_config` — Symbol referencing a database.yml config for DDL credentials (e.g., `:db_manager`). Requires adapter-level support for credential overlay within `Tenant.switch`.
- `schema_cache_per_tenant` — Boolean for per-tenant cache files vs single canonical.
- `app_role` — PostgreSQL RBAC privilege grants on tenant create.

## PendingMigrationError

Development-only runtime check. When a tenant's connection pool is created and the tenant has pending migrations, raise `Apartment::PendingMigrationError`. Gated behind `Rails.env.local?` (covers development and test). In production, migrations should have already run in the deploy pipeline.

Deferred to Phase 5 (runtime concern, not a Migrator concern). Requires adding `Apartment::PendingMigrationError` to `errors.rb` in that phase.

## Testing Strategy

### Unit tests (no database required)

All Migrator core logic testable with mocks/stubs:

- Thread coordination (work queue, sequential mode, empty tenant list)
- Result tracking (`MigrationRun#success?`, `#summary`, all status states)
- Tenant switching (verifies `Tenant.switch` called for each tenant)
- Advisory lock disabling (verifies `@advisory_locks_enabled` set on leased connection)
- Primary abort on failure (verifies early return, tenants not attempted)
- Schema dumper prefix stripping and version gating
- Failure isolation (one tenant's failure doesn't halt others)

### Integration tests (real databases)

Against PostgreSQL (schema-based) and SQLite (file-based):

- End-to-end migrate: create tenants, add migration, run Migrator, verify table exists in each schema
- Parallel correctness: 4+ tenants with `threads: 2`, verify no cross-tenant leakage, all tenants migrated
- Partial failure: one tenant has broken migration, others succeed, verify `MigrationRun` reflects both
- Schema dump: run Migrator, verify `schema.rb` has no `public.` prefix; verify `structure.sql` is clean
- Idempotency: run Migrator twice, second run returns all `:skipped` results
- Version targeting: `VERSION=` env var passed through to `context.migrate`

**Deferred to Phase 5:**
- RBAC flow: `migration_db_config: :db_manager`, verify DDL runs with elevated credentials, runtime pools use `app_user` (PostgreSQL only)

### Out of scope

- Thor CLI tests (Phase 6)
- Per-tenant schema cache integration tests (unit coverage sufficient)
- MySQL RBAC integration (MySQL doesn't have schema-based tenancy; RBAC concern is PG-specific in our test matrix)

## Files

```
lib/apartment/
├── migrator.rb              # NEW — Migrator, Result, MigrationRun
├── schema_dumper_patch.rb   # NEW — Rails 8.1 public. prefix stripping
├── config.rb                # MODIFY — new config keys
├── tasks/v4.rake            # MODIFY — wire through Migrator
├── railtie.rb               # MODIFY — db:migrate:DBNAME enhancement hook

spec/unit/
├── migrator_spec.rb         # NEW
├── schema_dumper_patch_spec.rb  # NEW

spec/integration/v4/
├── migrator_integration_spec.rb  # NEW
```

## Out of Scope (Phase 4)

- Thor CLI commands (Phase 6)
- RBAC privilege management / `app_role` config (Phase 5)
- `PendingMigrationError` runtime check (Phase 5)
- Per-tenant connection configs / multi-shard support (future)
- `ARTENANT=` single-tenant targeting (future)
- Per-schema advisory locks (rejected; see rationale above)
