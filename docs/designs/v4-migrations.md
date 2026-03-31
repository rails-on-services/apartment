# v4 Migrations — Design Spec

## Overview

This spec covers the Migrator, schema dumper patch, schema cache generation, and rake/Thor task integration for Apartment v4. The Migrator is a standalone orchestrator that runs ActiveRecord migrations across all tenants with optional thread-based parallelism, using its own ephemeral connection pools with configurable credentials (RBAC support).

**Primary goal:** `Apartment::Migrator` migrates the public schema and all tenant schemas, with per-tenant result tracking, thread parallelism, and RBAC credential separation — without relying on v4's runtime pool-per-tenant infrastructure or dynamic `SET search_path` switching.

**Secondary goals:**
- Fix Rails 8.1 `public.` prefix regression in `schema.rb` dumps
- Support both `schema.rb` and `structure.sql` as schema formats
- Provide schema cache generation (single canonical or per-tenant)
- Wire into `db:migrate:DBNAME` for zero-config defaults while keeping `apartment:migrate` for full control

## Context & Motivation

### Why a standalone Migrator?

v4's runtime model is pool-per-tenant with `app_user` credentials and immutable connection configs. Migrations need different credentials (`db_manager` with DDL permissions) and a different lifecycle (ephemeral pools, created and destroyed within a single run). Mixing migration pools into the runtime PoolManager would conflate two distinct operational contexts.

The Migrator owns a dedicated `PoolManager` instance. Each pool bakes the tenant's schema into its connection config (no dynamic `search_path` switching), consistent with v4's core invariant: connection config is immutable per pool, tenant identity is baked in at pool creation.

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

Standalone orchestrator. Owns its lifecycle, connection pools, and thread coordination.

**Constructor:**

```ruby
Apartment::Migrator.new(
  threads: 8,                          # 0 = sequential (default)
  migration_db_config: :db_manager,    # database.yml config name for DDL credentials (nil = use tenant's own)
)
```

- `threads`: concurrency level. `0` means sequential (safe default for development, CI debugging).
- `migration_db_config`: resolved via `ActiveRecord::Base.configurations`. When set, credentials (username, password, optionally host) are overlaid onto each tenant's resolved config. When `nil`, each tenant's config is used as-is (supports tenants that supply their own migration role).

**Execution flow:**

```
Migrator#run
  ├── Phase 1: Migrate public schema (migration_db_config, blocking)
  ├── Phase 2: Migrate tenant schemas (parallel or sequential)
  │     ├── Resolve tenants from tenants_provider
  │     ├── For each tenant:
  │     │     ├── adapter.resolve_connection_config(tenant)
  │     │     ├── Overlay migration_db_config credentials (if set)
  │     │     ├── Create ephemeral pool from merged config
  │     │     ├── Run ActiveRecord::MigrationContext#migrate(version)
  │     │     ├── Record Result (success/failure + timing)
  │     │     └── Disconnect pool
  │     └── Collect Results
  ├── Phase 3: Dump schema (schema.rb or structure.sql)
  ├── Phase 4: Generate schema cache (if configured)
  └── Return MigrationRun (summary + per-tenant results)
```

### Connection Config Resolution

For each tenant, the Migrator builds an immutable connection config through three steps:

1. `adapter.resolve_connection_config(tenant)` — base config (host, database/schema, port)
2. Overlay migration credentials — shallow merge of `username`, `password`, and optionally `host` from `migration_db_config`. Everything else (schema search_path, database name, port) comes from step 1.
3. Create pool from merged config — immutable, tenant-specific, ephemeral

If `migration_db_config` is nil, step 2 is a no-op. The overlay logic is adapter-agnostic; it only touches credentials. This design naturally supports future multi-shard scenarios where tenants specify their own database details and migration roles.

### Pool Lifecycle

The Migrator creates a dedicated `PoolManager` instance in its constructor. Pools are created on demand and kept alive for the duration of that tenant's migration sequence (multiple migration steps may reuse the connection). After all tenants complete, `PoolManager#clear` disconnects everything. No pool survives past `Migrator#run`. No PoolReaper is needed (pools are ephemeral and explicitly disconnected).

### Thread Coordination

Work-stealing via `Queue` (stdlib, thread-safe). Each thread pops a tenant from the queue, migrates it, records the result, and pops the next. Results collected in a `Concurrent::Array`. No shared mutable state beyond these two thread-safe structures.

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
)

def succeeded = results.select { _1.status == :success }
def failed    = results.select { _1.status == :failed }
def skipped   = results.select { _1.status == :skipped }
def success?  = failed.empty?
```

**Reporting:** `MigrationRun#summary` returns a formatted string for logging. The Migrator emits `ActiveSupport::Notifications` events (`apartment.migrate_tenant`) per tenant, consistent with v4's instrumentation pattern.

**Failure handling:** A failed tenant does not halt the run. All tenants are attempted. The caller inspects `migration_run.success?` and decides the response (raise, log, alert).

## Schema Dumper Patch

### Problem

Rails 8.1 added schema-qualified table names to `schema.rb` output (e.g., `create_table "public.users"`). When loaded into a tenant schema, tables land in `public` instead of the tenant's schema.

### Solution

Patch `ActiveRecord::SchemaDumper` to strip the `public.` prefix during dump. Applied conditionally (Rails >= 8.1 only). The dumped `schema.rb` is schema-agnostic — works for both public and tenant schemas.

`structure.sql` is unaffected: raw SQL `CREATE TABLE users` (without schema qualification) defaults to the current `search_path`.

### `include_schemas_in_dump`

Config option: array of schema names that retain their prefix in `schema.rb` dumps. Tables in these schemas keep the qualified name (e.g., `"extensions.some_table"`). Tables in `public` get stripped.

Default: `[]` (strip all `public.` prefixes).

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
apartment:migrate                    # uses config defaults
apartment:migrate VERSION=20260401   # specific version
apartment:rollback STEP=2
```

These delegate to the Migrator. The existing v4.rake tasks are updated to wire through the Migrator instead of direct adapter calls.

### `db:migrate:DBNAME` enhancement

When Apartment is loaded, the Railtie enhances `db:migrate:primary` (or whatever the primary database config is named) to also invoke `apartment:migrate`. This provides Rails-native compatibility without requiring users to know about Apartment's task namespace.

The enhancement must not interfere with other database configs (e.g., `db:migrate:ddl_workspace`).

### Composability with existing Thor tasks

CampusESP uses `schema:pristine` and `schema:baseline` Thor tasks for schema management. These operate on a separate `ddl_workspace` database config and use `db:migrate:ddl_workspace`. The Migrator's `db:migrate:primary` enhancement is scoped to the primary config only; these tasks are unaffected.

The baseline loader migration uses `connection_db_config` to resolve credentials for `psql`. When running through the Migrator with `migration_db_config: :db_manager`, the pool's config flows through to `ActiveRecord::Base.connection_db_config`, so `psql` gets the elevated credentials.

## Configuration

New config options added in Phase 4:

```ruby
Apartment.configure do |c|
  # Migrator
  c.migration_db_config = :db_manager   # Symbol — database.yml config name for DDL credentials (nil = use tenant's own)
  c.parallel_migration_threads = 8      # Integer — 0 = sequential (default)

  # Schema dump
  c.include_schemas_in_dump = []         # Array<String> — schemas that retain public. prefix in schema.rb

  # Schema cache
  c.schema_cache_per_tenant = false      # Boolean — per-tenant cache files vs single canonical
end
```

Dropped from design: `parallel_strategy`, `:processes`, `:auto`.

Designed-in but deferred to Phase 5: `app_role` (PostgreSQL RBAC privilege grants on tenant create).

## PendingMigrationError

Development-only runtime check. When a tenant's connection pool is created and the tenant has pending migrations, raise `Apartment::PendingMigrationError`. Gated behind `Rails.env.local?` (covers development and test). In production, migrations should have already run in the deploy pipeline.

Deferred to Phase 5 (runtime concern, not a Migrator concern).

## Testing Strategy

### Unit tests (no database required)

All Migrator core logic testable with mocks/stubs:

- Config resolution and credential overlay
- Thread coordination (work queue, sequential mode, empty tenant list)
- Result tracking (`MigrationRun#success?`, `#summary`, all status states)
- Pool lifecycle (create on demand, disconnect after run)
- Schema dump dispatch (`:schema_rb` vs `:sql`, prefix stripping for `schema.rb` only)
- Schema cache modes (shared vs per-tenant, generation skipped when unconfigured)
- Failure isolation (one tenant's failure doesn't halt others)

### Integration tests (real databases)

Against PostgreSQL (schema-based) and SQLite (file-based):

- End-to-end migrate: create tenants, add migration, run Migrator, verify table exists in each schema
- RBAC flow: `migration_db_config: :db_manager`, verify DDL runs with elevated credentials, runtime pools use `app_user` (PostgreSQL only)
- Parallel correctness: 4+ tenants with `threads: 4`, verify no cross-tenant leakage, all tenants migrated
- Partial failure: one tenant has broken migration, others succeed, verify `MigrationRun` reflects both
- Schema dump: run Migrator, verify `schema.rb` has no `public.` prefix; verify `structure.sql` is clean
- Idempotency: run Migrator twice, second run returns all `:skipped` results

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
