# lib/apartment/ - Core Implementation Directory

This directory contains v4 implementation files. v3 files have been deleted as of Phase 2.5. See `docs/designs/apartment-v4.md` for the v4 architecture.

## Directory Structure

```
lib/apartment/
├── adapters/              # Database-specific tenant isolation (see CLAUDE.md)
│   ├── abstract_adapter.rb    # Base adapter: lifecycle, callbacks, resolve_connection_config, base_config
│   ├── postgresql_schema_adapter.rb  # Schema-per-tenant (CREATE/DROP SCHEMA, schema_search_path)
│   ├── postgresql_database_adapter.rb # Database-per-tenant on PostgreSQL (CREATE/DROP DATABASE)
│   ├── mysql2_adapter.rb      # Database-per-tenant on MySQL (mysql2 driver)
│   ├── trilogy_adapter.rb     # Database-per-tenant on MySQL (trilogy driver, inherits Mysql2Adapter)
│   └── sqlite3_adapter.rb     # File-per-tenant (FileUtils lifecycle)
├── configs/               # Database-specific config objects
│   ├── postgresql_config.rb   # PostgresqlConfig: persistent_schemas, enforce_search_path_reset
│   └── mysql_config.rb        # MysqlConfig: placeholder
├── elevators/             # Rack middleware for tenant detection (see CLAUDE.md); v4 uses constructor keyword args, no class-level state; Generic, Subdomain, FirstSubdomain, Domain, Host, HostHash, Header
├── patches/               # ActiveRecord patches for tenant-aware connections
│   └── connection_handling.rb # Prepends on AR::Base — tenant-aware connection_pool
├── tasks/                 # Rake task utilities; v4.rake for apartment:create/drop/migrate/seed/rollback
├── config.rb              # Configuration with validate!/freeze!
├── current.rb             # Fiber-safe tenant context (CurrentAttributes)
├── errors.rb              # Exception hierarchy
├── instrumentation.rb     # ActiveSupport::Notifications wrapper
├── migrator.rb            # Migration orchestrator: sequential/parallel, Result/MigrationRun value objects
├── pool_manager.rb        # Concurrent::Map pool cache with monotonic timestamps
├── pool_reaper.rb         # Background idle/LRU pool eviction
├── railtie.rb             # Rails initialization (activate!, middleware, rake tasks)
├── schema_dumper_patch.rb # Rails 8.1 schema dump fix: strips public. prefix from table names
├── tenant.rb              # Public API facade (switch, current, reset, lifecycle)
├── tenant_name_validator.rb  # Pure in-memory tenant name format validation
└── version.rb             # Gem version constant
```

## v4 Files

### tenant.rb — Public API

`switch(tenant) { ... }` sets `Current.tenant` via ensure block. Delegates lifecycle ops (`create`, `drop`, `migrate`, `seed`) to `Apartment.adapter`. No thread-local state — uses `CurrentAttributes` for fiber safety.

### config.rb — Configuration

`Apartment.configure { |c| ... }` builds config, validates, freezes. Prepare-then-swap pattern: failed configure preserves previous working config. Frozen after validation — tests must reconfigure, not stub.

### current.rb — Tenant Context

`ActiveSupport::CurrentAttributes` subclass with `tenant` and `previous_tenant` attributes. Fiber-safe, auto-reset per request by Rails.

### pool_manager.rb — Pool Cache

`Concurrent::Map` storing connection pools by tenant key. Monotonic clock timestamps for idle/LRU tracking. `stats_for` returns `{ seconds_idle: N }`. `clear` disconnects all pools before clearing.

### pool_reaper.rb — Pool Eviction

Background `Concurrent::TimerTask` instance that evicts idle and excess tenant pools. Created by `Apartment.configure`, stored as `Apartment.pool_reaper`. Deregisters evicted pools from AR's ConnectionHandler. Default tenant is never evicted.

### adapters/abstract_adapter.rb — Base Adapter

Lifecycle ops (`create`, `drop`, `migrate`, `seed`), `ActiveSupport::Callbacks` on `:create`/`:switch`, `resolve_connection_config` (abstract — subclasses override), `process_excluded_models`, `environmentify`, `base_config` (stringified `connection_config`), `rails_env` (guarded `Rails.env` access). Constructor takes `connection_config` (raw AR hash, not `Apartment::Config`).

### Concrete Adapters (Phase 2.2)

All inherit from `AbstractAdapter`. Override `resolve_connection_config`, `create_tenant`, `drop_tenant`.

- **PostgresqlSchemaAdapter** — `schema_search_path` with persistent schemas. Does NOT environmentify (schemas are named directly). `CREATE/DROP SCHEMA IF EXISTS ... CASCADE`.
- **PostgresqlDatabaseAdapter** — `database` key with environmentified name. `CREATE/DROP DATABASE IF EXISTS`.
- **Mysql2Adapter** — Same pattern as PostgresqlDatabaseAdapter. `CREATE/DROP DATABASE IF EXISTS`.
- **TrilogyAdapter** — Empty subclass of Mysql2Adapter (alternative MySQL driver).
- **Sqlite3Adapter** — `database` key with file path. `FileUtils.mkdir_p` for create, `FileUtils.rm_f` for drop.

### railtie.rb — v4 Rails Integration

Three hooks in Rails boot order:
1. `config.after_initialize` — Guards on `Apartment.config.nil?`, warns if isolation_level is `:thread`, calls `activate!` and `Tenant.init`
2. `initializer 'apartment.middleware'` — Inserts elevator if `config.elevator` set, resolves via `resolve_elevator_class` (symbols, strings, or classes), passes `elevator_options` as keyword args, emits boot-time trust warning for Header elevator without `trusted: true`
3. `rake_tasks` — Loads `tasks/v4.rake` (apartment:create, :drop, :migrate, :seed, :rollback)

### migrator.rb — Migration Orchestrator

`Apartment::Migrator` runs migrations across all tenants with optional thread-based parallelism. Owns a dedicated `PoolManager` instance with ephemeral pools for RBAC credential separation. `Result` (Data.define) tracks per-tenant success/failure/skip. `MigrationRun` aggregates results with `#success?`, `#summary`. Constructor accepts `threads:` (0=sequential) and `migration_db_config:` (Symbol referencing database.yml config for DDL credentials).

### schema_dumper_patch.rb — Rails 8.1 Schema Fix

Patches `ActiveRecord::SchemaDumper` to strip `public.` prefix from table names in `schema.rb` output. Applied conditionally for Rails 8.1+ via `SchemaDumperPatch.apply!` (called by Railtie). Respects `PostgresqlConfig#include_schemas_in_dump` for non-public schemas that should retain their prefix.

### tenant_name_validator.rb — Name Validation

Pure module, no IO. `validate!(name, strategy:, adapter_name:)` checks common rules (non-empty, no NUL, no whitespace, max 255) then engine-specific: PG identifiers (max 63, no `pg_` prefix), MySQL names (max 64, no leading digit), SQLite paths (no traversal).

## Data Flow

**Tenant creation**: `Tenant.create` → `adapter.create` → `TenantNameValidator.validate!` → callbacks → `create_tenant` (subclass) → `import_schema` (if configured) → instrumentation

**Tenant switching (v4)**: `Tenant.switch` → `Current.tenant =` → yield → ensure restore. No SQL switching — connection pool resolved by `ConnectionHandling` patch (Phase 2.3).

**Migration flow**: `Migrator#run` → Phase 1: migrate primary (default tenant) → Phase 2: migrate tenants (sequential or parallel via threads) → Phase 3: schema dump → return `MigrationRun`

**Request flow**: HTTP → Elevator middleware → `Tenant.switch` → app processes → ensure cleanup
