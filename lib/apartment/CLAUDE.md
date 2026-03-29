# lib/apartment/ - Core Implementation Directory

This directory contains v3 and v4 code side by side. Zeitwerk `loader.ignore` directives in `lib/apartment.rb` control which files load. v3 files are being replaced incrementally — see `docs/designs/apartment-v4.md` for the v4 architecture.

## Directory Structure

```
lib/apartment/
├── adapters/              # Database-specific tenant isolation (see CLAUDE.md)
│   ├── abstract_adapter.rb    # [v4] Base adapter: lifecycle, callbacks, resolve_connection_config, base_config
│   ├── postgresql_schema_adapter.rb  # [v4] Schema-per-tenant (CREATE/DROP SCHEMA, schema_search_path)
│   ├── postgresql_database_adapter.rb # [v4] Database-per-tenant on PostgreSQL (CREATE/DROP DATABASE)
│   ├── mysql2_adapter.rb      # [v4] Database-per-tenant on MySQL (mysql2 driver)
│   ├── trilogy_adapter.rb     # [v4] Database-per-tenant on MySQL (trilogy driver, inherits MySQL2Adapter)
│   ├── sqlite3_adapter.rb     # [v4] File-per-tenant (FileUtils lifecycle)
│   ├── postgresql_adapter.rb  # [v3] PostgreSQL schema switching (legacy, Zeitwerk-ignored)
│   └── *_jdbc_*.rb            # [v3] JRuby adapters (dropped in v4, Zeitwerk-ignored)
├── configs/               # [v4] Database-specific config objects
│   ├── postgresql_config.rb   # persistent_schemas, enforce_search_path_reset
│   └── mysql_config.rb        # placeholder
├── active_record/         # [v3] ActiveRecord patches (to be replaced Phase 2.3)
├── elevators/             # Rack middleware for tenant detection (see CLAUDE.md)
├── patches/               # [v4] ActiveRecord patches for tenant-aware connections
│   └── connection_handling.rb # [v4] Prepends on AR::Base — tenant-aware connection_pool
├── tasks/                 # Rake task utilities, parallel migrations (see CLAUDE.md)
├── config.rb              # [v4] Configuration with validate!/freeze!
├── current.rb             # [v4] Fiber-safe tenant context (CurrentAttributes)
├── errors.rb              # [v4] Exception hierarchy
├── instrumentation.rb     # [v4] ActiveSupport::Notifications wrapper
├── pool_manager.rb        # [v4] Concurrent::Map pool cache with monotonic timestamps
├── pool_reaper.rb         # [v4] Background idle/LRU pool eviction
├── tenant.rb              # [v4] Public API facade (switch, current, reset, lifecycle)
├── console.rb             # [v3] Rails console helpers
├── custom_console.rb      # [v3] Enhanced console with tenant prompt
├── deprecation.rb         # [v3] Deprecation warnings
├── log_subscriber.rb      # [v3] ActiveRecord log subscriber
├── migrator.rb            # [v3] Tenant migration runner
├── model.rb               # [v3] Excluded model behavior (to be replaced Phase 2.4)
├── railtie.rb             # [v3] Rails initialization hooks
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

Background `Concurrent::TimerTask` that evicts idle and excess tenant pools. Default tenant is never evicted. Class-level singleton with mutex.

### adapters/abstract_adapter.rb — Base Adapter

Lifecycle ops (`create`, `drop`, `migrate`, `seed`), `ActiveSupport::Callbacks` on `:create`/`:switch`, `resolve_connection_config` (abstract — subclasses override), `process_excluded_models`, `environmentify`, `base_config` (stringified `connection_config`), `rails_env` (guarded `Rails.env` access). Constructor takes `connection_config` (raw AR hash, not `Apartment::Config`).

### Concrete Adapters (Phase 2.2)

All inherit from `AbstractAdapter`. Override `resolve_connection_config`, `create_tenant`, `drop_tenant`.

- **PostgreSQLSchemaAdapter** — `schema_search_path` with persistent schemas. Does NOT environmentify (schemas are named directly). `CREATE/DROP SCHEMA IF EXISTS ... CASCADE`.
- **PostgreSQLDatabaseAdapter** — `database` key with environmentified name. `CREATE/DROP DATABASE IF EXISTS`.
- **MySQL2Adapter** — Same pattern as PostgreSQLDatabaseAdapter. `CREATE/DROP DATABASE IF EXISTS`.
- **TrilogyAdapter** — Empty subclass of MySQL2Adapter (alternative MySQL driver).
- **SQLite3Adapter** — `database` key with file path. `FileUtils.mkdir_p` for create, `FileUtils.rm_f` for drop.

## v3 Files (still active, replaced incrementally)

- **railtie.rb** — Rails boot integration, excluded model setup, rake task loading
- **migrator.rb** — Tenant migration iteration with parallel support
- **model.rb** — Excluded model connection handling (to be replaced Phase 2.4)
- **console.rb / custom_console.rb** — Rails console tenant helpers
- **active_record/** — v3 AR patches (to be removed; replaced by v4 patches/connection_handling.rb)
- **adapters/postgresql_adapter.rb** — v3 schema switching (Zeitwerk-ignored, replaced by v4 PostgreSQLSchemaAdapter)

## Data Flow

**Tenant creation**: `Tenant.create` → `adapter.create` → callbacks → `create_tenant` (subclass) → instrumentation

**Tenant switching (v4)**: `Tenant.switch` → `Current.tenant =` → yield → ensure restore. No SQL switching — connection pool resolved by `ConnectionHandling` patch (Phase 2.3).

**Request flow**: HTTP → Elevator middleware → `Tenant.switch` → app processes → ensure cleanup
