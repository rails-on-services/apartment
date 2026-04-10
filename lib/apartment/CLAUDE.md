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
├── concerns/              # ActiveRecord concerns for tenant-aware models
│   └── model.rb               # Apartment::Model concern: pin_tenant, pinned identity, table-name helpers
├── configs/               # Database-specific config objects
│   ├── postgresql_config.rb   # PostgresqlConfig: persistent_schemas, include_schemas_in_dump
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

Lifecycle ops (`create`, `drop`, `migrate`, `seed`), `ActiveSupport::Callbacks` on `:create`/`:switch`, `resolve_connection_config` (abstract — subclasses override), `process_excluded_models`, `environmentify`, `base_config` (stringified `connection_config`), `rails_env` (guarded `Rails.env` access). `process_pinned_model` / `qualify_pinned_table_name` call **`Apartment::Model` class methods** (`apartment_explicit_table_name?`, `apartment_mark_processed!`, etc.); no `instance_variable_*` on arbitrary model classes. Constructor takes `connection_config` (raw AR hash, not `Apartment::Config`).

### Concrete Adapters (Phase 2.2)

All inherit from `AbstractAdapter`. Override `resolve_connection_config`, `create_tenant`, `drop_tenant`.

- **PostgresqlSchemaAdapter** — `schema_search_path` with persistent schemas. Does NOT environmentify (schemas are named directly). `CREATE/DROP SCHEMA IF EXISTS ... CASCADE`.
- **PostgresqlDatabaseAdapter** — `database` key with environmentified name. `CREATE/DROP DATABASE IF EXISTS`.
- **Mysql2Adapter** — Same pattern as PostgresqlDatabaseAdapter. `CREATE/DROP DATABASE IF EXISTS`.
- **TrilogyAdapter** — Empty subclass of Mysql2Adapter (alternative MySQL driver).
- **Sqlite3Adapter** — `database` key with file path. `FileUtils.mkdir_p` for create, `FileUtils.rm_f` for drop.

### concerns/model.rb — Model Pinning Concern

`Apartment::Model` provides `pin_tenant` (class method) to declare a model as pinned to the default tenant. Registered models bypass the `ConnectionHandling` patch when the adapter uses a separate pool; when shared pinned connections are enabled, routing follows the tenant pool (see design docs). Zeitwerk-safe: works whether called before or after `activate!`.

**Identity:** `apartment_pinned?` — the class answers whether it is pinned (ivars + superclass walk). `Apartment.pinned_model?(klass)` delegates to `klass.apartment_pinned?` when the concern is included; otherwise it falls back to registry lookup (`pinned_models`) for `excluded_models` shim classes that never included the concern.

**Table naming:** `apartment_explicit_table_name?` — whether `self.table_name` was explicitly set vs convention (compares `@table_name` to `compute_table_name`). Lives here so adapters do not read `@table_name` or call `compute_table_name` from outside; **class instance variable access for pinning is confined to this concern**.

**Lifecycle:** `apartment_pinned_processed?`, `apartment_mark_processed!`, `apartment_restore!` — qualification state and teardown. Adapters call these; `Apartment.clear_config` uses `apartment_restore!` with `respond_to?` so shim-registered models without the concern still clear safely. `apartment_mark_pinned!` — sets the pinned flag without triggering processing (used by `process_pinned_model` for shim classes to avoid `pin_tenant` recursion).

**Deferred processing:** When `Apartment.activated?` is true (Zeitwerk lazy-load path), `pin_tenant` defers `process_pinned_model` via `apartment_defer_processing!` — a one-shot `TracePoint(:end)` constrained to `Thread.current`. Only `:end` is used: `:b_return` fires for ALL block returns in class context (each, include hooks) and would trigger prematurely; `:raise` is not used because rescued raises still produce `:end` (MRI verified). For `Class.new { }` (tests, runtime metaprogramming), `:end` does not fire; call `process_pinned_model` explicitly. Models loaded before `activate!` are unaffected (processed in batch by `Tenant.init`). Reopening a pinned class does not re-trigger processing (idempotent via `apartment_pinned?`).

**Shim compatibility:** `process_pinned_model` dynamically includes `Apartment::Model` on classes registered via the `excluded_models` shim that lack the concern. This is a runtime `include` on a partially-booted class — acceptable for the legacy shim path but new code should always use `include Apartment::Model` + `pin_tenant` explicitly.

### railtie.rb — v4 Rails Integration

Three hooks in Rails boot order:
1. `config.after_initialize` — Guards on `Apartment.config.nil?`, warns if isolation_level is `:thread`, calls `activate!` and `Tenant.init`
2. `initializer 'apartment.middleware'` — Inserts elevator if `config.elevator` set, resolves via `resolve_elevator_class` (symbols, strings, or classes), passes `elevator_options` as keyword args, emits boot-time trust warning for Header elevator without `trusted: true`
3. `rake_tasks` — Loads `tasks/v4.rake` (apartment:create, :drop, :migrate, :seed, :rollback)

### migrator.rb — Migration Orchestrator

`Apartment::Migrator` runs migrations across all tenants with optional thread-based parallelism. Delegates to `Apartment::Tenant.switch` for each tenant — the `ConnectionHandling` patch routes `AR::Base.connection_pool` to the tenant's pool, so Rails' migration machinery (which hardcodes `AR::Base.lease_connection`) uses the correct connection automatically. No standalone pools or handler swaps. Disables PG advisory locks for tenant migrations (database-wide locks serialize parallel execution; see issue #298). `Result` (Data.define) tracks per-tenant success/failure/skip. `MigrationRun` aggregates results with `#success?`, `#summary`. Primary migration aborts the run on failure (tenants are never touched). Constructor accepts `threads:` (0=sequential). RBAC credential separation (`migration_db_config`) is deferred to Phase 5.

### schema_dumper_patch.rb — Rails 8.1 Schema Fix

Patches `ActiveRecord::SchemaDumper` to strip `public.` prefix from table names in `schema.rb` output. Applied conditionally for Rails 8.1+ via `SchemaDumperPatch.apply!` (called by Railtie). Respects `PostgresqlConfig#include_schemas_in_dump` for non-public schemas that should retain their prefix.

### tenant_name_validator.rb — Name Validation

Pure module, no IO. `validate!(name, strategy:, adapter_name:)` checks common rules (non-empty, no NUL, no whitespace, max 255) then engine-specific: PG identifiers (max 63, no `pg_` prefix), MySQL names (max 64, no leading digit), SQLite paths (no traversal).

## Data Flow

**Tenant creation**: `Tenant.create` → `adapter.create` → `TenantNameValidator.validate!` → callbacks → `create_tenant` (subclass) → `import_schema` (if configured) → instrumentation

**Tenant switching (v4)**: `Tenant.switch` → `Current.tenant =` → yield → ensure restore. No SQL switching — connection pool resolved by `ConnectionHandling` patch (Phase 2.3).

**Migration flow**: `Migrator#run` → Phase 1: migrate primary (default tenant) → Phase 2: migrate tenants (sequential or parallel via threads) → Phase 3: schema dump → return `MigrationRun`

**Request flow**: HTTP → Elevator middleware → `Tenant.switch` → app processes → ensure cleanup
