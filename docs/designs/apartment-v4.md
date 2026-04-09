# Apartment v4 Design Spec

## Overview

Apartment v4 is a ground-up rewrite of the `ros-apartment` gem, replacing v3's thread-local `SET search_path` switching model with an immutable connection-pool-per-tenant architecture. The rewrite addresses fundamental concurrency, safety, and compatibility limitations in v3 while preserving its proven patterns (adapters, elevators, callbacks, excluded models).

**Primary goals:**
- Eliminate tenant context leakage via immutable per-tenant connection pools
- Full thread and fiber safety via `ActiveSupport::CurrentAttributes`
- PgBouncer/RDS Proxy compatibility (reduced session pinning via connection-level config)
- Rails 7.2, 8.0, 8.1 support; Ruby 3.3+
- Sub-millisecond tenant switching for cached pools

**Build approach:** Fresh branch off `development`. The v4 alpha branch (`man/spec-restart`) serves as reference architecture. Production-hardened v3.3-3.4 features (parallel migrations, multi-db rake tasks, Rails 8.x compatibility) are ported and adapted.

**What this is not:** An incremental refactor of v3. This is a clean break with a deprecation bridge in v3.5.

## Context & Motivation

### Problems with v3

1. **Thread-local tenant state** (`Thread.current[:apartment_adapter]`): Not fiber-safe, breaks with `load_async`, `ActionController::Live`, and async frameworks. (#199, #239, #304)
2. **`SET search_path` switching**: Causes session pinning in PgBouncer/RDS Proxy transaction mode, preventing connection reuse. (#302)
3. **Connection leaks under load**: `establish_connection` called per switch creates unbounded connections with multiple workers/threads. (#323)
4. **Rails 8.1 schema dump regression**: `public.` prefix in `schema.rb` breaks tenant table creation. (#341)
5. **Cross-thread state sharing**: No safe propagation of tenant context to background jobs, async queries, or streaming responses.

### Prior art

- **PR #327** (`man/spec-restart`): v4 alpha with pool-per-tenant, `CurrentAttributes`, `TenantConnectionDescriptor`. Mostly complete but WIP — missing rake tasks, CLI, some strategy stubs (`NotImplementedError`), and v3.3-3.4 features.
- **Discussion #312**: Community input on concurrency, fiber safety, `CurrentAttributes`, Rails connection pool integration, schema dumping.
- **37signals Writebook**: Rails 8 native multi-tenancy via `connected_to(tenant:)` with SQLite-per-tenant. Validates the direction but lacks schema-based tenancy, lifecycle management, and middleware.

### What v4 preserves from v3

- Adapter pattern (PostgreSQL, MySQL, SQLite — database-specific implementations behind unified API)
- Elevator middleware (Rack-based tenant detection from request attributes)
- Callback system (`ActiveSupport::Callbacks` on `:create` and `:switch`)
- Excluded models (shared tables pinned to default tenant)
- Configuration philosophy (dynamic tenant discovery via callable, fail-fast validation)
- Parallel migration infrastructure (simplified for pool-per-tenant)
- Multi-database rake task enhancement (v3.4.1)

## Version Requirements

| Dependency | Minimum | Rationale |
|-----------|---------|-----------|
| Ruby | 3.3+ | 3.2 EOL April 2026 |
| Rails | 7.2+ | Aligns with Rails support policy; `migration_context` on `connection_pool` (not `connection`); no legacy connection handling shims |
| Sidekiq | No constraint | Auto-detected at boot; works on 7+ and 8+ via `CurrentAttributes` |
| PostgreSQL | 14+ | 13 and below EOL; schema-based tenancy baseline |
| MySQL | 8.4+ | 8.0 EOL April 2026; 8.4 LTS supported through 2032 |

## Architecture

### Core: Tenant Context via CurrentAttributes

```ruby
# lib/apartment/current.rb
class Apartment::Current < ActiveSupport::CurrentAttributes
  attribute :tenant
  attribute :previous_tenant
end
```

Replaces `Thread.current[:apartment_adapter]`. Benefits:
- Fiber-safe (each fiber gets its own attribute store)
- Auto-reset between requests by Rails
- Natively propagated by Sidekiq 7+ and SolidQueue
- Propagated to `load_async` threads and `ActionController::Live` threads

**Important caveat:** `CurrentAttributes` propagation to `load_async` threads depends on `config.active_support.isolation_level`. In Rails 7.2+, the default is `:fiber`, which provides proper isolation. If a user has explicitly set `isolation_level: :thread`, `load_async` spawns a new thread without propagating attributes. v4's Railtie should validate that `isolation_level` is `:fiber` (or warn if it's `:thread`) to ensure correct behavior. This is documented in the upgrade guide.

### Core: Immutable Connection Pool Per Tenant

Each tenant gets its own connection pool with tenant-specific config baked in at creation time.

**PostgreSQL (schema strategy):**
```ruby
def resolve_connection_config(tenant)
  base_config.merge(
    schema_search_path: [tenant, *persistent_schemas].map { |s| %("#{s}") }.join(",")
  )
end
# Example: schema_search_path: '"acme","ext","public"'
```

**MySQL (database_name strategy):**
```ruby
def resolve_connection_config(tenant)
  base_config.merge(database: tenant_database_name(tenant))
end
```

No `SET search_path` at switch time. The connection *is* the tenant context. Pools are:
- **Lazily created** on first access
- **Cached** in a thread-safe `Concurrent::Map`
- **Evicted** when idle (configurable timeout, LRU)
- **Immutable** — config doesn't change after creation

**PgBouncer/RDS Proxy compatibility:**

v3 issues `SET search_path` on every tenant switch (per request). v4 eliminates per-switch `SET` entirely — the `schema_search_path` is baked into the connection config, so tenant switching is a pool lookup, not a SQL command.

However, Rails' `PostgreSQLAdapter#configure_connection` still issues a one-time `SET search_path` when establishing each new connection. This means:

- **Without PgBouncer**: No issue. Connections are long-lived; the `SET` happens once at creation.
- **With PgBouncer in session mode**: No issue. Session-pinned connections are expected.
- **With PgBouncer in transaction mode**: The initial `SET` may cause session pinning. Two mitigations:
  1. **Preferred**: Use libpq connection string `options: '-c search_path=tenant,ext,public'` which sets the search_path at the protocol level during connection establishment, avoiding a `SET` statement entirely. v4 should attempt this approach first.
  2. **Fallback**: Configure PgBouncer with `ignore_startup_parameters = search_path` or use `track_extra_parameters = search_path` (PgBouncer 1.20+, requires Citus 12+ for `GUC_REPORT` support on search_path).
  3. **Alternative**: Use `SET LOCAL search_path` inside each transaction (scoped to transaction, PgBouncer does not pin on `SET LOCAL`). This is closer to v3's approach but only executes once per transaction, not once per switch.

The implementation should try approach (1) first and fall back to the Rails default if the database driver doesn't support connection string options. This is a significant improvement over v3 regardless — v3 issues `SET search_path` on every request; v4 issues it at most once per connection establishment.

### Pool Resolution & Storage

Tenant pools are managed by `Apartment::PoolManager`, which wraps a `Concurrent::Map` and integrates with ActiveRecord's `ConnectionHandler`.

**Pool storage approach:** Pools are registered with ActiveRecord's `ConnectionHandler` using tenant-qualified connection specification names. This leverages Rails' built-in pool lifecycle (checkout, checkin, reaping, stat tracking) rather than reimplementing it.

```ruby
# Pseudocode: pool resolution in Apartment::Patches::ConnectionHandling
module Apartment::Patches::ConnectionHandling
  def connection_pool
    tenant = Apartment::Current.tenant
    return super if tenant.nil? || tenant == Apartment.config.default_tenant

    pool_key = "#{connection_specification_name}[#{tenant}]"

    Apartment.pool_manager.fetch_or_create(pool_key) do
      config = Apartment::Tenant.adapter.resolve_connection_config(tenant)
      handler = ActiveRecord::Base.connection_handler
      # Register a new pool with ActiveRecord's handler using tenant-specific config
      pool_config = ActiveRecord::ConnectionAdapters::PoolConfig.new(
        ActiveRecord::Base,
        ActiveRecord::DatabaseConfigurations::HashConfig.new(
          Rails.env, pool_key, config
        ),
        :writing,
        tenant.to_sym  # Use tenant as shard identifier within AR's handler
      )
      # NOTE: This pseudocode illustrates intent. The actual implementation should
      # prefer public APIs (e.g., establish_connection with tenant-qualified config)
      # over send(:private_method) to reduce coupling to Rails internals across versions.
      handler.send(:owner_to_pool_manager, pool_key).put_pool_config(pool_config)
    end
  end
end
```

**Key design decisions:**
- `Apartment.pool_manager` uses `Concurrent::Map` for thread-safe tenant -> pool_key mapping
- Actual pool instances live inside ActiveRecord's `ConnectionHandler`, giving us free compatibility with `database_cleaner`, `strong_migrations`, and other gems that inspect `ActiveRecord::Base.connection_pool`
- When `Apartment::Current.tenant` is `nil` (e.g., during `db:migrate` with no request context), `super` is called, returning the default connection pool
- The `pool_key` format (`ClassName[tenant]`) prevents collisions with user-defined multi-db configs

### Pool Eviction Mechanics

Pool eviction uses a `Concurrent::TimerTask` (non-blocking periodic timer from the `concurrent-ruby` gem, already a Rails dependency):

```ruby
# Started in Railtie after_initialize
Apartment::PoolReaper.start(
  interval: Apartment.config.pool_idle_timeout,  # Check interval in seconds
  idle_timeout: Apartment.config.pool_idle_timeout,
  max_total: Apartment.config.max_total_connections
)
```

**Important distinction:** `Apartment::PoolReaper` evicts entire tenant pools (inter-pool eviction). ActiveRecord's built-in `ConnectionPool::Reaper` reaps idle connections within a single pool (intra-pool reaping). These are complementary — AR's reaper handles connection-level cleanup; Apartment's handles tenant-pool-level cleanup.

**Eviction behavior:**
- The reaper runs on a background thread at `pool_idle_timeout` intervals
- For each tenant pool, checks `last_accessed` timestamp
- Pools idle beyond `pool_idle_timeout` are disconnected and removed from both `Apartment.pool_manager` and ActiveRecord's `ConnectionHandler`
- If `max_total_connections` is set and exceeded, LRU eviction removes the least-recently-accessed pools until under the limit
- The default tenant pool is never evicted

**Interaction with forking servers (Puma, Unicorn):**
- The reaper timer is NOT started during `preload_app` / before fork
- Railtie registers an `on_worker_boot` callback that starts the reaper in each forked worker
- Each worker's `Concurrent::Map` starts empty (pools are re-created lazily after fork)
- ActiveRecord's own `clear_all_connections!` on fork is respected

**Graceful shutdown:**
- `Apartment::PoolReaper.stop` is registered as an `at_exit` hook
- Cancels the timer and disconnects all tenant pools cleanly

### Pool Sizing & Eviction

With 600+ tenants, naive pool-per-tenant would exhaust database connections. Smart pool management keeps it bounded:

| Config | Default | Purpose |
|--------|---------|---------|
| `tenant_pool_size` | `5` | Connections per tenant pool (matches Rails default) |
| `pool_idle_timeout` | `300` | Seconds before idle pool connections are reclaimed |
| `max_total_connections` | `nil` | Optional hard cap; LRU-evicts when exceeded |

**Steady state for a 5-thread Puma worker:**
- Active connections at any instant: 5 (one per thread, one tenant each)
- Cached idle connections: proportional to recently-accessed tenants
- With 60-300s eviction, only "hot" tenants maintain pools

**Example: 600 tenants, 10 Puma workers, 5 threads each:**
- If ~50 tenants are hot per worker in a given minute: ~50 pools × 1-2 active connections ≈ 50-100 connections per worker
- Across fleet: ~500-1000 total connections (well within typical `max_connections` budgets)

### Pool Observability

```ruby
Apartment::Tenant.pool_stats
# => {
#   total_pools: 47,
#   total_connections: 142,
#   active_connections: 5,
#   idle_connections: 137,
#   evictions_total: 312,
#   evictions_last_hour: 8,
#   pools_by_tenant: { "acme" => { size: 5, active: 1, idle: 4, last_accessed: ... }, ... }
# }
```

ActiveSupport::Notifications instrumentation:
```ruby
ActiveSupport::Notifications.subscribe("apartment.pool_stats") do |event|
  StatsD.gauge("apartment.total_pools", event.payload[:total_pools])
  StatsD.gauge("apartment.total_connections", event.payload[:total_connections])
end
```

Thor commands:
```bash
apartment pool:stats              # Summary
apartment pool:stats --verbose    # Per-tenant breakdown
apartment pool:evict              # Force idle pool eviction
```

### Switching API

```ruby
Apartment::Tenant.switch("acme") { ... }  # Block-scoped, guaranteed cleanup
Apartment::Tenant.switch!("acme")          # Direct switch (discouraged)
Apartment::Tenant.current                   # Reads Apartment::Current.tenant
Apartment::Tenant.reset                     # Returns to default tenant
```

`switch` sets `Apartment::Current.tenant`, looks up (or lazily creates) the pool, yields, and restores `previous_tenant` in an `ensure` block.

### Cross-Tenant Queries & Transactions

**What works:** Cross-schema queries. PostgreSQL allows `SELECT * FROM other_schema.table` regardless of the connection's `search_path`. A tenant connection can read/write excluded model tables in the `public` schema.

**What doesn't work:** Wrapping a tenant write and an excluded-model write in a single database transaction. Different pools = different connections = can't share a transaction.

**Excluded models pool ownership:** Excluded models get a dedicated, shared connection pool pinned to the default tenant. This pool is separate from the default tenant's pool in the `Concurrent::Map` — it is registered once during `Apartment::Tenant.init` via `establish_connection` on each excluded model class (same pattern as v3). The excluded models pool is never evicted. This means:
- Excluded model queries always go through the default tenant pool, regardless of `Apartment::Current.tenant`
- A tenant context and an excluded model can be used in the same request, but on different connections
- Cross-schema reads work (PostgreSQL allows `SELECT * FROM public.users` from any connection)
- Cross-pool transactions do NOT work — a tenant write and an excluded model write cannot share a database transaction

**Migration guidance for affected users (e.g., delayed_job in untenanted DB):** Writing a job record from a tenant context works because the excluded model's connection handles it independently. The trade-off is that the job insert and the tenant data change are not in the same transaction. If transactional consistency is required, users should move the job table into tenant schemas or use a two-phase approach.

## Configuration

```ruby
# config/initializers/apartment.rb
Apartment.configure do |config|
  # Required: isolation strategy
  config.tenant_strategy = :schema  # :schema, :database_name, :shard, :database_config

  # Required: callable returning current tenant list
  config.tenants_provider = -> { Company.pluck(:subdomain) }

  # Default tenant (PostgreSQL: "public", MySQL: derived from database.yml)
  config.default_tenant = "public"

  # Models in shared/default tenant
  config.excluded_models = %w[User Company]

  # Schemas always in search_path (PostgreSQL only)
  # Common pattern: ["ext", "public"] for extensions in a dedicated schema
  config.persistent_schemas = %w[ext public]

  # Environment-aware tenant naming
  config.environmentify_strategy = :prepend  # :prepend, :append, or nil

  # Tenant lifecycle
  config.seed_after_create = false
  config.seed_data_file = "db/seeds/tenants.rb"

  # Pool management
  config.tenant_pool_size = 5        # Connections per tenant pool
  config.pool_idle_timeout = 300     # Seconds before idle pool eviction
  config.max_total_connections = nil  # Optional hard cap

  # Parallel migrations
  config.parallel_migration_threads = 0  # 0 = sequential
  config.parallel_strategy = :auto       # :auto (threads), :threads, :processes (opt-in)

  # Elevator (auto-inserted as middleware via middleware.use)
  # Always pass a class — Rack instantiates it with (app). Use elevator_options for config.
  config.elevator = Apartment::Elevators::Subdomain
  # For Header elevator:
  # config.elevator = Apartment::Elevators::Header
  # config.elevator_options = { header: "X-Tenant-Id", trusted: true }

  # Tenant-not-found handling
  config.tenant_not_found_handler = ->(tenant, request) {
    [404, {}, ["Tenant not found"]]
  }

  # Database-specific config blocks
  config.configure_postgres do |pg|
    pg.persistent_schemas = %w[ext public]
    pg.enforce_search_path_reset = true
    pg.include_schemas_in_dump = %w[ext shared]
  end

  config.configure_mysql do |mysql|
    # MySQL-specific options
  end
end
```

**Config precedence:** Database-specific blocks (`configure_postgres`, `configure_mysql`) override top-level settings. For example, if `config.persistent_schemas = %w[public]` and `pg.persistent_schemas = %w[ext public]`, the PostgreSQL adapter uses `["ext", "public"]`. Top-level settings serve as defaults for adapters that don't have a specific block.

**Changes from v3:**

| v3 | v4 | Notes |
|----|-----|-------|
| `tenant_names` (array or callable) | `tenants_provider` (must be callable) | Stricter interface |
| `use_schemas = true` | `tenant_strategy = :schema` | Explicit, covers all four strategies |
| `prepend_environment` / `append_environment` | `environmentify_strategy = :prepend` | Single setting |
| `current_tenant` | `current` | API cleanup |
| `reset!` | `reset` | API cleanup |
| N/A | `tenant_pool_size`, `pool_idle_timeout` | New pool management |
| N/A | `config.elevator = ...` | Auto-insertion (was manual middleware.use) |
| N/A | `tenant_not_found_handler` | Configurable error handling |
| N/A | `pg.include_schemas_in_dump` | Addresses #303 |

## Adapters

### Hierarchy

```
Apartment::Adapters::AbstractAdapter
  +-- PostgreSQLSchemaAdapter     (:schema + postgresql)
  +-- PostgreSQLDatabaseAdapter   (:database_name + postgresql)
  +-- MySQL2Adapter               (:database_name + mysql2)
  +-- TrilogyAdapter              (:database_name + trilogy)
  +-- SQLite3Adapter              (:database_name + sqlite3)
```

JDBC adapters dropped (negligible JRuby usage, high maintenance). PostGIS adapter dropped (users should use the PostgreSQL adapters with PostGIS-enabled connections; the adapters handle isolation the same way).

**Strategy x Database matrix:**

| Strategy | PostgreSQL | MySQL | SQLite |
|----------|-----------|-------|--------|
| `:schema` | PostgreSQLSchemaAdapter | N/A | N/A |
| `:database_name` | PostgreSQLDatabaseAdapter | MySQL2Adapter / TrilogyAdapter | SQLite3Adapter |
| `:shard` | delegates to Rails `connected_to` | same | same |
| `:database_config` | full config override per tenant | same | same |

Adapter selection is automatic based on `tenant_strategy` + the database adapter detected from `database.yml`. The `:schema` strategy is only valid with PostgreSQL — using it with MySQL or SQLite raises `ConfigurationError` at boot.

**Why PostgreSQL supports both strategies:** Schema-per-tenant (`:schema`) is the primary and recommended path — fast switching, shared connection pool benefits, and `persistent_schemas` for extensions. Database-per-tenant (`:database_name`) provides stronger isolation boundaries: separate `pg_dump` per tenant, independent extensions, and full database-level access control. Use database-per-tenant when regulatory or security requirements demand complete isolation.

The `:shard` and `:database_config` strategies reuse the same adapter classes but with different `resolve_connection_config` implementations.

### AbstractAdapter

Responsibilities:
- `create(tenant)` — create schema/database, run migrations, optionally seed
- `drop(tenant)` — drop schema/database, remove cached pool
- `switch(tenant, &block)` — set `Current.tenant`, resolve pool, yield, restore
- `switch!(tenant)` — direct switch without block
- `reset` — switch to default tenant
- `migrate(tenant, version)` — run migrations within tenant's pool
- `seed(tenant)` — run seeds within tenant context

Callbacks via `ActiveSupport::Callbacks` on `:create` and `:switch` (same as v3).

### PostgreSQLSchemaAdapter

Primary strategy. Pool config sets `schema_search_path` at connection creation time.

```ruby
def resolve_connection_config(tenant)
  base_config.merge(
    schema_search_path: [tenant, *persistent_schemas].map { |s| %("#{s}") }.join(",")
  )
end
```

Handles:
- Schema creation/dropping via `CREATE SCHEMA` / `DROP SCHEMA CASCADE`
- Extension availability via `persistent_schemas` (e.g., `["ext", "public"]` ensures `pgcrypto`, `uuid-ossp` etc. are accessible in tenant schemas — addresses #321)
- Rails 8.1 schema dump patch: strips `public.` prefix when loading structure into tenant schemas (#341)
- Excluded model table names prefixed: `public.users`

### PostgreSQLDatabaseAdapter

Database-per-tenant on PostgreSQL. Same pool-per-tenant model, but varies `database` instead of `schema_search_path`.

```ruby
def resolve_connection_config(tenant)
  base_config.merge(database: tenant_database_name(tenant))
end
```

Handles:
- Database creation/dropping via `CREATE DATABASE` / `DROP DATABASE`
- Each tenant has fully independent schemas, extensions, and access control
- Excluded model table names reference the default database: `default_db.users`

Trade-offs vs schema adapter:
- (+) Stronger isolation (separate `pg_dump`, independent extensions, database-level `GRANT`)
- (+) No `search_path` concerns — each database is self-contained
- (-) Slower switching (new connection per database vs search_path change)
- (-) Cannot cross-query between tenants (no `other_schema.table` access)
- (-) Higher connection count (one pool per database, not shared)

### MySQL2Adapter / TrilogyAdapter

Pool config sets `database` at connection creation time.

```ruby
def resolve_connection_config(tenant)
  base_config.merge(database: tenant_database_name(tenant))
end
```

Excluded model table names prefixed: `default_db.users`.

### SQLite3Adapter

File-per-tenant isolation. Development/testing use case.

## Elevators (Middleware)

### Strategies

```
Apartment::Elevators::Generic        # Base class
  +-- Subdomain                      # tenant from subdomain (PublicSuffix)
  +-- FirstSubdomain                 # first segment of nested subdomains
  +-- Domain                         # domain minus TLD
  +-- Host                           # full hostname
  +-- HostHash                       # hostname -> tenant lookup table
  +-- Header                         # tenant from trusted HTTP header (NEW)
```

### Base Pattern

```ruby
class Generic
  def initialize(app, processor = nil)
    @app = app
    @processor = processor || method(:parse_tenant_name)
  end

  def call(env)
    request = Rack::Request.new(env)
    tenant = @processor.call(request)

    if tenant
      Apartment::Tenant.switch(tenant) { @app.call(env) }
    else
      @app.call(env)
    end
  end
end
```

Exception-safe by design — `switch` block guarantees cleanup.

### Header Elevator (New)

For infrastructure that injects tenant identity at the edge (CloudFront, Nginx, API gateway).

```ruby
config.elevator = Apartment::Elevators::Header
config.elevator_options = { header: "X-Tenant-Id", trusted: true }
```

Security model:
- `trusted: false` (default): logs a prominent warning at boot — "Header-based tenant resolution trusts the client to provide the correct tenant. Only use this when the header is injected by trusted infrastructure (CDN, reverse proxy) that strips client-supplied values."
- `trusted: true`: warning suppressed; developer has acknowledged the trust model
- Missing header: falls through to default tenant (same as other elevators returning nil)

**Example pattern:** A CloudFront or Nginx edge function strips any client-injected `X-Tenant-Id` header, then sets it only from a trusted lookup (KVS, database, config). The app can trust the header because it can only arrive through the trusted edge layer.

## Job Middleware

### Core Mechanism

`Apartment::Current.tenant` propagated via `ActiveSupport::CurrentAttributes`.

### Sidekiq (7+)

Sidekiq natively serializes/restores `CurrentAttributes`. Apartment ships a server middleware that reads the restored value and establishes the pool context:

```ruby
class Apartment::Jobs::SidekiqMiddleware
  def call(worker, job, queue)
    tenant = Apartment::Current.tenant
    if tenant
      Apartment::Tenant.switch(tenant) { yield }
    else
      yield
    end
  end
end
```

Auto-registered via Railtie if Sidekiq is detected. No Sidekiq version constraint declared — works on 7+ and 8+.

### SolidQueue

Natively propagates `CurrentAttributes`. Same pattern — hook reads `Apartment::Current.tenant` and establishes pool context.

### ActiveJob (Generic Fallback)

For job backends that don't support `CurrentAttributes` natively, an `around_perform` callback serializes tenant into job metadata:

```ruby
# In ApplicationJob:
include Apartment::Jobs::ActiveJobExtension
```

### Custom Integrations

Public API: `Apartment::Current.tenant` (read), `Apartment::Tenant.switch(tenant) { ... }` (establish context).

## Migrations & Rake Tasks

### Simplified Parallel Migrations

v3's 293-line parallel migration orchestration (fork-vs-thread detection, advisory lock management, connection pool clearing) is simplified because pool-per-tenant eliminates connection contention.

**What's gone:**
- Advisory lock management (each pool has its own lock space)
- Connection clearing/re-establishment after fork
- Platform detection defaults to threads

**What remains:**
- `parallel_strategy: :auto` resolves to `:threads` (default)
- `parallel_strategy: :processes` available as opt-in for Linux deployments with CPU-heavy migrations
- `Result` struct with per-tenant success/failure tracking
- `display_summary` showing succeeded/failed counts
- Schema dump after migration from canonical default tenant

### Multi-Database Rake Task Enhancement

Carried from v3.4.1. Detects Rails multi-database configs and auto-enhances namespaced tasks:
- `db:migrate:primary` -> `apartment:migrate`
- `db:rollback:primary` -> `apartment:rollback`
- `db:seed:primary` -> `apartment:seed`

Only enhances databases with `database_tasks: true` and `replica: false`.

### Thor CLI (Primary Interface)

```bash
apartment create                  # Create all tenants
apartment create acme             # Create specific tenant
apartment drop acme               # Drop specific tenant
apartment migrate                 # Migrate all tenants
apartment migrate acme            # Migrate specific tenant
apartment rollback --steps=2      # Rollback all tenants
apartment seed                    # Seed all tenants
apartment list                    # List all tenants
apartment current                 # Show current tenant
apartment pool:stats              # Pool usage summary
apartment pool:stats --verbose    # Per-tenant breakdown
apartment pool:evict              # Force idle pool eviction
```

The `apartment` command is made available via a binstub generated by `rails generate apartment:install` (creates `bin/apartment`) or by adding `ros-apartment` to the `Gemfile` (Thor auto-discovers the CLI via the gem's `lib/apartment/cli.rb`).

### Rake Tasks (Thin Wrappers)

Rake tasks delegate to Thor commands for backward compatibility:

```ruby
namespace :apartment do
  task migrate: :environment do
    Apartment::CLI.new.migrate
  end
end
```

## Rails Integration (Railtie)

```ruby
class Apartment::Railtie < Rails::Railtie
  initializer "apartment.configure" do
    Apartment.validate_config!  # Fail fast: tenant_strategy required, tenants_provider must be callable

    # Warn if isolation_level is :thread — CurrentAttributes won't propagate to load_async
    if Rails.application.config.active_support.isolation_level == :thread
      Rails.logger.warn "[Apartment] active_support.isolation_level is :thread. " \
        "Apartment requires :fiber (Rails 7.2+ default) for correct tenant propagation " \
        "to load_async and ActionController::Live threads."
    end
  end

  initializer "apartment.process_excluded_models", after: :load_config_initializers do
    config.to_prepare do
      Apartment::Tenant.init  # Process excluded models, establish default pools
    end
  end

  initializer "apartment.middleware" do |app|
    if Apartment.config.elevator
      opts = Apartment.config.elevator_options || {}
      app.middleware.use Apartment.config.elevator, **opts
    end
  end

  initializer "apartment.job_middleware" do
    if defined?(Sidekiq)
      Sidekiq.configure_server do |config|
        config.server_middleware do |chain|
          chain.add Apartment::Jobs::SidekiqMiddleware
        end
      end
    end
  end

  initializer "apartment.current_attributes" do
    ActiveSupport.on_load(:active_record) do
      Apartment::Current  # Ensure loaded for propagation
    end
  end

  rake_tasks do
    load "apartment/tasks.rb"
  end
end
```

### ActiveRecord Patches

Minimal surface via `prepend` (not v3's `alias_method` chains):

```ruby
ActiveSupport.on_load(:active_record) do
  ActiveRecord::Base.prepend Apartment::Patches::ConnectionHandling
end
```

Patched methods:
- `connection_pool` — returns tenant-specific pool based on `Apartment::Current.tenant`
- `retrieve_connection` — tenant-aware connection checkout
- `establish_connection` — tenant-aware pool creation

Everything else delegates to Rails' native behavior.

### Rails 8.1 Schema Dumper Patch

Addresses #341. When loading `schema.rb` into a tenant schema, strips `public.` prefix from table names so tables are created in the tenant's schema rather than `public`.

Configurable `include_schemas_in_dump` for users who need non-tenant schemas (shared, analytics, extensions) in their schema dump (#303).

## Error Handling

### Exception Hierarchy

```
Apartment::ApartmentError               # Base class
  +-- Apartment::TenantNotFound         # Tenant doesn't exist
  +-- Apartment::TenantExists           # Tenant already exists (on create)
  +-- Apartment::AdapterNotFound        # Invalid tenant_strategy
  +-- Apartment::ConfigurationError     # Missing/invalid config (tenant_strategy, tenants_provider)
  +-- Apartment::PoolExhausted          # max_total_connections exceeded, eviction couldn't free pools
  +-- Apartment::SchemaLoadError        # Failed to load schema into tenant (migration/structure issue)
```

### tenants_provider Error Handling

`tenants_provider` is called at runtime (tenant creation, migration, listing). Failure modes:

- **Database unavailable / table doesn't exist**: Rescued with `ActiveRecord::StatementInvalid` and `ActiveRecord::NoDatabaseError`. Returns empty array. Logs warning. This matches v3's behavior and allows the app to boot even if the tenants table hasn't been migrated yet.
- **Returns non-array**: `ConfigurationError` raised at call time.
- **Stale data**: Not cached by default. Each call hits the callable fresh. Users who want caching should implement it in their callable (e.g., `Rails.cache.fetch`).

### Pool Error Handling

- **Connection checkout timeout** within a tenant pool: ActiveRecord's `ConnectionTimeoutError` propagates unmodified. Users tune via `tenant_pool_size` or `checkout_timeout`.
- **Pool creation failure** (e.g., database connection refused): `ActiveRecord::ConnectionNotEstablished` propagates. The pool is NOT cached in the `Concurrent::Map` on failure, so the next access retries.
- **`max_total_connections` exceeded**: LRU eviction runs. If no pools can be evicted (all active), raises `Apartment::PoolExhausted`.

### Elevator Error Handling

- **Tenant not found** (elevator resolves a tenant name that doesn't exist): Calls `config.tenant_not_found_handler` if configured. Default behavior: raises `Apartment::TenantNotFound`.
- **Elevator raises**: Exception propagates to Rack error handling. No tenant context is set.

## Generator

`rails generate apartment:install` creates `config/initializers/apartment.rb` with annotated defaults. Carried forward from v3 with updated config keys.

```bash
rails generate apartment:install
# Creates config/initializers/apartment.rb with v4 config template
```

## Backward Compatibility with apartment-sidekiq

The upgrade guide (step 6) notes removing the `apartment-sidekiq` gem. Additional handling:

- **Detection**: If `Apartment::Sidekiq` (from the old gem) is defined at boot, v4 logs a warning: "apartment-sidekiq is not needed with Apartment 4.x. Built-in Sidekiq middleware handles tenant propagation via CurrentAttributes. Remove apartment-sidekiq from your Gemfile."
- **Job format compatibility**: Jobs enqueued with v3 + `apartment-sidekiq` store the tenant in `job["apartment"]`. v4's Sidekiq middleware checks for this key as a fallback if `Apartment::Current.tenant` is nil, enabling zero-downtime upgrades where old-format jobs are still in the queue during the transition.
- **No conflict**: If both are loaded, v4's middleware takes precedence (registered later in the chain). The old gem's middleware becomes a no-op since the tenant is already set.

## Notification Events

Following ActiveSupport::Notifications `"verb.namespace"` convention:

| Event | Payload | When |
|-------|---------|------|
| `switch.apartment` | `{ tenant:, previous_tenant: }` | Tenant switch (block or bang) |
| `create.apartment` | `{ tenant: }` | Tenant created |
| `drop.apartment` | `{ tenant: }` | Tenant dropped |
| `evict.apartment` | `{ tenant:, reason: }` | Pool evicted (idle/lru) |
| `pool_stats.apartment` | `{ total_pools:, total_connections:, ... }` | Periodic stats (if subscribed) |

## Testing Strategy

### Test Structure

```
spec/
  unit/
    config_spec.rb
    current_spec.rb
    tenant_spec.rb
    adapters/
      abstract_adapter_spec.rb
      postgresql_adapter_spec.rb
      mysql2_adapter_spec.rb
      trilogy_adapter_spec.rb
    elevators/
      subdomain_spec.rb
      first_subdomain_spec.rb
      domain_spec.rb
      host_spec.rb
      host_hash_spec.rb
      header_spec.rb
    jobs/
      sidekiq_middleware_spec.rb
      solid_queue_spec.rb
      active_job_extension_spec.rb
    migrator_spec.rb
    tasks/
      task_helper_spec.rb
      schema_dumper_spec.rb
      rake_task_enhancer_spec.rb
    cli_spec.rb
    pool_manager_spec.rb
  integration/
    connection_pool_isolation_spec.rb
    thread_safety_spec.rb
    fiber_safety_spec.rb
    request_lifecycle_spec.rb
    migration_spec.rb
    excluded_models_spec.rb
  stress/
    rapid_switching_spec.rb
    concurrent_access_spec.rb
    memory_stability_spec.rb
    pool_eviction_spec.rb
  dummy/
    # Minimal Rails app for integration tests
```

### CI Matrix

**Appraisals:**
- Rails 7.2 + PostgreSQL
- Rails 7.2 + MySQL
- Rails 8.0 + PostgreSQL
- Rails 8.0 + MySQL
- Rails 8.0 + SQLite3
- Rails 8.1 + PostgreSQL
- Rails 8.1 + MySQL
- Rails 8.1 + SQLite3

**Ruby:** 3.3 and 3.4

**Database selection:** `DB=postgresql rspec` (or `mysql`, `sqlite3`) — same env var as v3 for contributor continuity.

## Upgrade Path

### v3.5.0 (Deprecation Bridge)

Final v3.x release with deprecation warnings pointing to v4 equivalents:

```ruby
config.tenant_names = [...]
# => DEPRECATION: tenant_names is removed in Apartment 4.0.
#    Use tenants_provider with a callable instead.

config.use_schemas = true
# => DEPRECATION: use_schemas is removed in Apartment 4.0.
#    Use tenant_strategy = :schema instead.

Apartment::Tenant.current_tenant
# => DEPRECATION: current_tenant is removed in Apartment 4.0. Use .current instead.

Apartment::Tenant.reset!
# => DEPRECATION: reset! is removed in Apartment 4.0. Use .reset instead.
```

### v4.0.0 Upgrade Guide

Checklist format in `docs/upgrading-to-v4.md`:

1. **Prerequisites**: Ruby 3.3+, Rails 7.2+
2. **Configuration migration**: v3 -> v4 config key mapping table
3. **API changes**: `current_tenant` -> `current`, `reset!` -> `reset`, `tenant_names` -> `tenants_provider`
4. **Initializer rewrite**: example v3 initializer -> equivalent v4 initializer
5. **Elevator changes**: same classes, optional `config.elevator` auto-insertion
6. **Job middleware**: remove `apartment-sidekiq` gem, built-in now
7. **Rake -> Thor**: `rake apartment:migrate` still works, `apartment migrate` preferred
8. **Excluded models**: no change required
9. **Test updates**: helpers referencing v3 internals

No compatibility shims in v4 — clean break.

**Gem naming:** stays `ros-apartment`. Version jump 3.5 -> 4.0 signals the break.

## Open Issues Resolution

| Issue | Status in v4 |
|-------|-------------|
| #302 PgBouncer/RDS Proxy session pinning | Improved: per-switch `SET` eliminated; connection-level config with libpq `options` avoids session pinning. See PgBouncer section for details. |
| #239 Concurrency in specs | Solved: `CurrentAttributes` provides thread/fiber isolation |
| #199 `load_async` ignores tenant | Solved: `CurrentAttributes` propagates to async threads |
| #304 ActionController::Live | Solved: `CurrentAttributes` propagates to spawned threads |
| #323 Connection leaks under load | Solved: pools cached in `Concurrent::Map`, lazy creation, eviction |
| #341 Rails 8.1 `public.` prefix | Solved: schema dumper patch strips prefix for tenant loading |
| #303 Missing `create_schema` in schema.rb | Solved: `include_schemas_in_dump` config option |
| #321 `gen_random_uuid()` not found | Solved: `persistent_schemas` includes extension schema by default |
| #339 Ruby 3.3 SyntaxError | Non-issue: fresh codebase, no anonymous block forwarding in nested contexts |
| #314 ActiveStorage multitenancy | Out of scope: document patterns, potential companion gem |

## Out of Scope

- **ActiveStorage integration**: Document patterns, potential `apartment-activestorage` companion gem
- **Rails `connects_to` wrapper for excluded models**: May add in v4.1+
- **Rails 8.2+ support**: Added as Rails releases
- **JDBC adapters**: Dropped; can return in 4.x if demand exists
- **Automatic shard swapping middleware**: Rails doesn't support this natively; users handle via custom middleware or `around_action`
