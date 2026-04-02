# Phase 5: Role-Aware Connections, RBAC, Schema Cache, Pending Migration Check

## Overview

Phase 5 makes Apartment v4's `ConnectionHandling` patch role-aware, enabling RBAC credential separation, replica routing, and custom role composition with tenant switching — all using Rails' native `connected_to(role:)` mechanism. It also adds per-tenant schema cache generation and a development-time pending migration check.

**Primary goal:** `connected_to(role: :reading) { Tenant.switch('acme') { ... } }` and `connected_to(role: :db_manager) { Tenant.switch('acme') { ... } }` create tenant pools with the correct base config for the active role, not hardcoded to the primary connection.

**Secondary goals:**
- Migrator uses configurable `migration_role` for elevated DDL credentials
- Automatic RBAC privilege grants on tenant creation (`app_role`)
- Optional per-tenant schema cache files
- Development-only `PendingMigrationError` on tenant pool creation

## Context & Motivation

### The Bug: ConnectionHandling Ignores Role

Phase 4's `ConnectionHandling#connection_pool` resolves tenant configs from the adapter's `base_config` — always the primary connection config (`@connection_config`). It passes `ActiveRecord::Base.current_role` to `establish_connection`, so the pool is *registered* under the correct role, but the *config* (host, username, password) always comes from the primary.

This means:
- `connected_to(role: :reading) { Tenant.switch('acme') { ... } }` creates a tenant pool registered under `:reading` but pointing at the primary host, not the replica
- `connected_to(role: :db_manager) { Tenant.switch('acme') { ... } }` creates a tenant pool with `app_user` credentials, not `db_manager`

These patterns are common in production multi-tenant apps:

```ruby
# DDL under elevated role
ActiveRecord::Base.connected_to(role: :db_manager) do
  Apartment::Tenant.switch(schema) do
    # expects db_manager credentials, actually gets app_user
  end
end

# Replica routing for read-heavy queries
ActiveRecord::Base.connected_to(role: :reading, prevent_writes: true) do
  # expects replica host, actually gets primary
end
```

Both patterns are silently broken. Fixing `ConnectionHandling` to be role-aware resolves RBAC credential separation, replica routing, and arbitrary custom role composition in one change.

### Why Roles, Not Credential Overlay

The original Phase 5 plan proposed `Current.credential_overlay` — a fiber-safe attribute that `ConnectionHandling` would check when creating pools, merging elevated credentials from a database.yml entry. Research during brainstorming revealed this is unnecessary because:

1. Production apps already register roles via `connects_to` in `ApplicationRecord`:

```ruby
connects_to database: {
  writing: :primary,
  reading: :primary_replica,
  db_manager: :db_manager,
}
```

2. Rails' `ConnectionHandler` stores pools in a `(connection_name, role, shard)` lookup structure. Each `(role, shard)` pair gets an independent `db_config`. Roles can have completely different host, port, username, password — they're fully independent configs.

3. `connected_to(role:)` pushes onto a per-fiber `connected_to_stack` (via `IsolatedExecutionState`). `current_role` reads from the stack top, falling back to `ActiveRecord.writing_role` (configurable via `config.active_record.writing_role`, defaults to `:writing`).

4. Making `ConnectionHandling` resolve base config from the current role's default pool is a 5-line change. The credential overlay approach would have required a new `Current` attribute, merge logic, pool eviction after migration, and a separate pool key namespace — all unnecessary complexity.

### Reference RBAC Architecture

A typical production setup uses two PostgreSQL roles:
- `app_user` — runtime DML (SELECT, INSERT, UPDATE, DELETE). No DDL privileges.
- `db_manager` — inherits `app_user` via `GRANT app_user TO db_manager`. Has CREATE privilege on databases. Owns schemas and objects created during migrations.

Both point at the same database with different credentials. `database.yml` maps them to separate named configs (`primary` and `db_manager`), registered as roles via `connects_to`.

A privilege fixer service grants `app_user` access to tenant schemas after restore operations:
1. `GRANT USAGE ON SCHEMA` — schema visibility
2. `GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES` — existing table access
3. `GRANT USAGE, SELECT ON ALL SEQUENCES` — sequence access for inserts
4. `ALTER DEFAULT PRIVILEGES ... ON TABLES` — future table access
5. `ALTER DEFAULT PRIVILEGES ... ON SEQUENCES` — future sequence access
6. `ALTER DEFAULT PRIVILEGES ... ON FUNCTIONS` — future function access

The `ALTER DEFAULT PRIVILEGES` trap: these only fire for objects created by the named grantor role. If `db_manager` sets the defaults but a migration runs as `app_user`, the grants silently don't apply. The invariant that resolves this: **migration role = grantor role = schema owner**.

## Role-Aware ConnectionHandling

### Pool Key Format

Pool keys change from `"#{tenant}"` to `"#{tenant}:#{role}"`. Always includes role — no special-casing for `:writing`.

Examples:
- `"acme:writing"` — runtime pool with app_user credentials
- `"acme:reading"` — replica pool
- `"acme:db_manager"` — elevated credentials pool

### Base Config Resolution

`ConnectionHandling#connection_pool` calls `super` (the original, un-patched method) to get the default tenant's pool for `current_role`. Extracts the pool's `db_config.configuration_hash` as the base config. Passes it to the adapter via `base_config_override:`.

```ruby
def connection_pool
  tenant = Apartment::Current.tenant
  cfg = Apartment.config
  return super if tenant.nil? || cfg.nil?
  return super if tenant.to_s == cfg.default_tenant.to_s
  return super unless Apartment.pool_manager

  role = ActiveRecord::Base.current_role
  pool_key = "#{tenant}:#{role}"

  Apartment.pool_manager.fetch_or_create(pool_key) do
    default_pool = super
    base = default_pool.db_config.configuration_hash.stringify_keys

    config = Apartment.adapter.validated_connection_config(tenant, base_config_override: base)

    prefix = cfg.shard_key_prefix
    shard_key = :"#{prefix}_#{pool_key}"

    db_config = ActiveRecord::DatabaseConfigurations::HashConfig.new(
      cfg.rails_env_name,
      "#{prefix}_#{pool_key}",
      config
    )

    pool = ActiveRecord::Base.connection_handler.establish_connection(
      db_config,
      owner_name: ActiveRecord::Base,
      role: role,
      shard: shard_key
    )

    if check_pending_migrations?(pool)
      raise Apartment::PendingMigrationError.new(tenant)
    end

    pool
  end
rescue Apartment::ApartmentError
  raise
rescue StandardError => e
  raise(Apartment::ApartmentError,
        "Failed to resolve connection pool for tenant '#{tenant}': #{e.class}: #{e.message}")
end
```

### Adapter Interface Change

`AbstractAdapter#validated_connection_config` and `resolve_connection_config` gain a `base_config_override:` / `base_config:` keyword:

```ruby
# abstract_adapter.rb
def validated_connection_config(tenant, base_config_override: nil)
  TenantNameValidator.validate!(
    tenant,
    strategy: Apartment.config.tenant_strategy,
    adapter_name: (base_config_override || base_config)['adapter']
  )
  resolve_connection_config(tenant, base_config: base_config_override || base_config)
end

# Subclasses override with base_config: keyword
def resolve_connection_config(tenant, base_config: nil)
  raise(NotImplementedError)
end
```

Each adapter's `resolve_connection_config` applies tenant-specific modifications on top of whatever base it receives:

```ruby
# postgresql_schema_adapter.rb
def resolve_connection_config(tenant, base_config: nil)
  config = base_config || self.base_config
  persistent = Apartment.config.postgres_config&.persistent_schemas || []
  search_path = [tenant, *persistent].join(',')
  config.merge('schema_search_path' => search_path)
end

# postgresql_database_adapter.rb
def resolve_connection_config(tenant, base_config: nil)
  config = base_config || self.base_config
  config.merge('database' => environmentify(tenant))
end

# mysql2_adapter.rb (trilogy inherits)
def resolve_connection_config(tenant, base_config: nil)
  config = base_config || self.base_config
  config.merge('database' => environmentify(tenant))
end

# sqlite3_adapter.rb
def resolve_connection_config(tenant, base_config: nil)
  config = base_config || self.base_config
  db_dir = config['database'] ? File.dirname(config['database']) : 'db'
  config.merge('database' => File.join(db_dir, "#{environmentify(tenant)}.sqlite3"))
end
```

This is an internal API change (only called by `ConnectionHandling`). v4 has no allegiance to v3's public API.

### Tenant Name Colon Restriction

The composite pool key format `"tenant:role"` uses `:` as a delimiter. Tenant names containing colons would produce ambiguous keys (e.g., `"foo:bar:writing"`). While `rpartition(':')` handles this correctly (splits on the last colon), adding `:` to `TenantNameValidator`'s common character blacklist eliminates the edge case entirely. Colons are invalid in PostgreSQL identifiers and MySQL database names anyway, so this restriction has no practical impact.

### What This Enables

| Caller pattern | Base config source | Tenant config |
|---|---|---|
| `Tenant.switch('acme') { ... }` | Primary (`:writing` role) | Primary + search_path |
| `connected_to(role: :reading) { Tenant.switch('acme') { ... } }` | Replica | Replica + search_path |
| `connected_to(role: :db_manager) { Tenant.switch('acme') { ... } }` | db_manager | db_manager + search_path |
| `connected_to(role: :cloning) { Tenant.switch('acme') { ... } }` | cloning_workspace | cloning_workspace + search_path |

Each combination gets its own pool, keyed by `"tenant:role"`, with the correct host/port/username/password for the active role.

### Pool Lifecycle: Drop, Eviction, and Deregistration

The pool key format change from `"#{tenant}"` to `"#{tenant}:#{role}"` cascades through three subsystems that manage pool lifecycle: `AbstractAdapter#drop`, `PoolReaper`, and `Apartment.deregister_shard`. All must handle composite keys correctly.

**`PoolManager#remove_tenant(tenant)` (new method):** Removes all pools for a tenant across all roles. Iterates pool keys matching `"#{tenant}:"` prefix. Returns an array of removed pools. Used by `AbstractAdapter#drop` and test teardown.

```ruby
# pool_manager.rb
def remove_tenant(tenant)
  prefix = "#{tenant}:"
  removed = []
  @pools.each_key do |key|
    next unless key.start_with?(prefix)
    pool = remove(key)
    removed << [key, pool] if pool
  end
  removed
end
```

**`AbstractAdapter#drop` update:** Currently calls `pool_manager.remove(tenant.to_s)` (single key). Updated to call `pool_manager.remove_tenant(tenant)` (removes all role variants). Deregisters each removed pool's shard from AR's ConnectionHandler:

```ruby
def drop(tenant)
  drop_tenant(tenant)
  removed_pools = Apartment.pool_manager&.remove_tenant(tenant) || []
  removed_pools.each do |pool_key, pool|
    begin
      pool&.disconnect! if pool.respond_to?(:disconnect!)
    rescue StandardError => e
      warn "[Apartment] Pool disconnect failed for '#{pool_key}': #{e.class}: #{e.message}"
    end
    Apartment.deregister_shard(pool_key)
  end
  Instrumentation.instrument(:drop, tenant: tenant)
end
```

**`Apartment.deregister_shard` update:** Currently builds the shard key from raw tenant name and uses `current_role`. Updated to accept the composite pool key (which already contains the role) and extract the role from it:

```ruby
def deregister_shard(pool_key)
  return unless @config && defined?(ActiveRecord::Base)

  # pool_key is "tenant:role" — extract the role for AR deregistration
  _tenant, _, role_str = pool_key.to_s.rpartition(':')
  role = role_str.empty? ? ActiveRecord.writing_role : role_str.to_sym

  shard_key = :"#{@config.shard_key_prefix}_#{pool_key}"
  ActiveRecord::Base.connection_handler.remove_connection_pool(
    'ActiveRecord::Base',
    role: role,
    shard: shard_key
  )
rescue StandardError => e
  warn "[Apartment] Failed to deregister AR pool for #{pool_key}: #{e.class}: #{e.message}"
end
```

**`PoolReaper` default tenant guard:** Currently checks `tenant == @default_tenant`. Updated to check the tenant prefix:

```ruby
def default_tenant_pool?(pool_key)
  pool_key.start_with?("#{@default_tenant}:")
end

# In evict_idle and evict_lru:
next if default_tenant_pool?(tenant)
```

**`PoolManager#evict_by_role(role)` (new convenience method):** Removes all pools whose key ends with `:#{role}`. Used by rake/Thor post-migration cleanup:

```ruby
def evict_by_role(role)
  suffix = ":#{role}"
  removed = []
  @pools.each_key do |key|
    next unless key.end_with?(suffix)
    pool = remove(key)
    removed << [key, pool] if pool
  end
  removed
end
```

## Migrator: `migration_role`

### Config

```ruby
Apartment.configure do |c|
  c.migration_role = :db_manager  # Symbol, default nil (uses current role)
end
```

### Integration

`with_migration_role` wraps both `migrate_primary` and each `migrate_tenant` call independently. This is necessary because `connected_to_stack` is per-fiber — worker threads in parallel migration need their own role context.

```ruby
def run
  start = monotonic_now

  primary_result = with_migration_role { migrate_primary }

  if primary_result.status == :failed
    return MigrationRun.new(
      results: [primary_result],
      total_duration: monotonic_now - start,
      threads: @threads
    )
  end

  tenants = Apartment.config.tenants_provider.call
  tenant_results = if @threads.positive?
                     run_parallel(tenants)
                   else
                     run_sequential(tenants)
                   end

  all_results = [primary_result, *tenant_results].compact

  MigrationRun.new(
    results: all_results,
    total_duration: monotonic_now - start,
    threads: @threads
  )
end

def migrate_tenant(tenant)
  start = monotonic_now
  with_migration_role do
    Apartment::Tenant.switch(tenant) do
      # ... migration logic (unchanged from Phase 4)
    end
  end
rescue StandardError => e
  Result.new(tenant: tenant, status: :failed, duration: monotonic_now - start, error: e, versions_run: [])
end

private

def with_migration_role(&)
  role = Apartment.config.migration_role
  role ? ActiveRecord::Base.connected_to(role: role, &) : yield
end
```

### Thread Safety

`connected_to` pushes onto a per-fiber `connected_to_stack` (uses `IsolatedExecutionState`). Each worker thread gets its own stack. The `with_migration_role` call inside `migrate_tenant` means each thread independently sets its role context. No shared mutable state.

### Post-Migration Pool Lifecycle

Tenant pools created under `:db_manager` (e.g., `"acme:db_manager"`) remain in `pool_manager` after migration. For deployments with hundreds of tenants, this means hundreds of idle `db_manager` connections for `pool_idle_timeout` seconds (default 300s). This is wasteful.

The Migrator calls `pool_manager.evict_by_role(migration_role)` in an `ensure` block after `run` completes. This immediately disconnects and removes all migration-role pools, deregistering them from AR's ConnectionHandler. Runtime pools (`:writing`) are unaffected.

```ruby
def run
  # ... migration logic
ensure
  evict_migration_pools
end

def evict_migration_pools
  role = Apartment.config.migration_role
  return unless role && Apartment.pool_manager

  Apartment.pool_manager.evict_by_role(role).each do |pool_key, _pool|
    Apartment.deregister_shard(pool_key)
  end
end
```

## RBAC Privilege Grants: `app_role`

### Config

```ruby
Apartment.configure do |c|
  c.app_role = 'app_user'  # String, callable, or nil (default)
end
```

- **String**: built-in engine-appropriate grants for that role name
- **Callable** `(tenant, connection)`: custom grant logic (escape hatch)
- **nil**: no grants

### Execution Point

Inside `AbstractAdapter#create`, after `create_tenant`, before `import_schema`:

```ruby
def create(tenant)
  TenantNameValidator.validate!(tenant, ...)
  run_callbacks(:create) do
    create_tenant(tenant)
    grant_tenant_privileges(tenant)
    import_schema(tenant) if Apartment.config.schema_load_strategy
    seed(tenant) if Apartment.config.seed_after_create
    Instrumentation.instrument(:create, tenant: tenant)
  end
end

private

def grant_tenant_privileges(tenant)
  app_role = Apartment.config.app_role
  return unless app_role

  conn = ActiveRecord::Base.connection
  if app_role.respond_to?(:call)
    app_role.call(tenant, conn)
  else
    grant_privileges(tenant, conn, app_role)
  end
end

# Default no-op; PG and MySQL adapters override
def grant_privileges(tenant, connection, role_name)
  # no-op
end
```

### PostgresqlSchemaAdapter Grants

Six statements mirroring `PgSchema::PrivilegeFixer`:

```ruby
def grant_privileges(tenant, connection, role_name)
  quoted_schema = connection.quote_table_name(tenant)
  quoted_role = connection.quote_table_name(role_name)

  connection.execute("GRANT USAGE ON SCHEMA #{quoted_schema} TO #{quoted_role}")

  connection.execute(
    "GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA #{quoted_schema} TO #{quoted_role}"
  )

  connection.execute(
    "GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA #{quoted_schema} TO #{quoted_role}"
  )

  # ALTER DEFAULT PRIVILEGES without FOR ROLE uses the current user.
  # When create runs inside connected_to(role: :db_manager), the
  # current user is db_manager — the schema owner and migration runner.
  # This enforces the invariant: migration role = grantor role = schema owner.
  connection.execute(
    "ALTER DEFAULT PRIVILEGES IN SCHEMA #{quoted_schema} " \
    "GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO #{quoted_role}"
  )

  connection.execute(
    "ALTER DEFAULT PRIVILEGES IN SCHEMA #{quoted_schema} " \
    "GRANT USAGE, SELECT ON SEQUENCES TO #{quoted_role}"
  )

  connection.execute(
    "ALTER DEFAULT PRIVILEGES IN SCHEMA #{quoted_schema} " \
    "GRANT EXECUTE ON FUNCTIONS TO #{quoted_role}"
  )
end
```

### Mysql2Adapter Grants

Single statement:

```ruby
def grant_privileges(tenant, connection, role_name)
  db_name = environmentify(tenant)
  quoted_role = connection.quote(role_name)
  connection.execute(
    "GRANT SELECT, INSERT, UPDATE, DELETE ON `#{db_name}`.* TO #{quoted_role}@'%'"
  )
end
```

Note: MySQL has no `quote_table_name` equivalent for role identifiers. `connection.quote` is used for the role name. Both `db_name` and `role_name` come from trusted config (not user input), but quoting is applied defensively.

### PostgresqlDatabaseAdapter

Database-per-tenant PG uses the `public` schema within each database. Grants operate on the database level, not schema level:

```ruby
def grant_privileges(tenant, connection, role_name)
  db_name = environmentify(tenant)
  quoted_role = connection.quote_table_name(role_name)
  connection.execute("GRANT CONNECT ON DATABASE #{connection.quote_table_name(db_name)} TO #{quoted_role}")
  connection.execute(
    "GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO #{quoted_role}"
  )
  connection.execute(
    "GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO #{quoted_role}"
  )
  connection.execute(
    "ALTER DEFAULT PRIVILEGES IN SCHEMA public " \
    "GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO #{quoted_role}"
  )
  connection.execute(
    "ALTER DEFAULT PRIVILEGES IN SCHEMA public " \
    "GRANT USAGE, SELECT ON SEQUENCES TO #{quoted_role}"
  )
end
```

Note: `GRANT CONNECT ON DATABASE` must run on the server-level connection (before switching into the tenant database). The table/sequence/default privilege grants run after switching into the tenant database. Implementation must handle this ordering — the `GRANT CONNECT` runs in `create_tenant` context (connected to the default database), while the remaining grants run inside `Tenant.switch(tenant)`. If the ordering is too complex, this can be deferred to the callable escape hatch. The built-in default for `PostgresqlDatabaseAdapter` may start as a no-op with documentation recommending the callable for database-per-tenant RBAC.

### Sqlite3Adapter

No override needed — inherits the no-op from `AbstractAdapter`.

### Key Invariant

**Migration role = grantor role = schema owner.** This holds because:
1. `Tenant.create` is called inside `connected_to(role: :db_manager)` (recommended pattern)
2. `CREATE SCHEMA` runs as db_manager — db_manager owns the schema
3. `ALTER DEFAULT PRIVILEGES` (no `FOR ROLE`) uses current user — db_manager is the grantor
4. Migrations run under `migration_role: :db_manager` — db_manager creates tables
5. Default privileges fire because the table creator (db_manager) matches the grantor

If a user doesn't use `connected_to(role: :db_manager)` when calling `Tenant.create`, the grants still execute (as whatever user is connected), but `ALTER DEFAULT PRIVILEGES` applies to that user. This is correct: the grantor is whoever creates objects. The invariant is self-enforcing.

### Callable Escape Hatch

For non-standard privilege models:

```ruby
Apartment.configure do |c|
  c.app_role = ->(tenant, conn) {
    conn.execute("GRANT USAGE ON SCHEMA #{conn.quote_table_name(tenant)} TO custom_role")
    conn.execute("GRANT SELECT ON ALL TABLES IN SCHEMA #{conn.quote_table_name(tenant)} TO readonly_role")
  }
end
```

## Schema Cache: `schema_cache_per_tenant`

### Config

```ruby
Apartment.configure do |c|
  c.schema_cache_per_tenant = true  # Boolean, default false
end
```

### Generation

Explicit via `Apartment::SchemaCache` module:

```ruby
module Apartment
  module SchemaCache
    module_function

    def dump(tenant)
      path = cache_path_for(tenant)
      Apartment::Tenant.switch(tenant) do
        ActiveRecord::Base.connection.schema_cache.dump_to(path)
      end
      path
    end

    def dump_all
      Apartment.config.tenants_provider.call.map { |t| dump(t) }
    end

    def cache_path_for(tenant)
      base = defined?(Rails) && Rails.root ? Rails.root.join('db') : Pathname.new('db')
      base.join("schema_cache_#{tenant}.yml").to_s
    end
  end
end
```

### Loading

When `schema_cache_per_tenant` is enabled and `ConnectionHandling` creates a new tenant pool, it checks for a tenant-specific cache file. If present, loads it into the pool's schema cache. If absent, the pool uses the canonical `db/schema_cache.yml` via normal Rails behavior.

```ruby
# Inside ConnectionHandling#connection_pool, after establish_connection
if Apartment.config.schema_cache_per_tenant
  cache_path = Apartment::SchemaCache.cache_path_for(tenant)
  if File.exist?(cache_path)
    pool.schema_cache.load!(cache_path)
  end
end
```

### Rake Task

```ruby
namespace :apartment do
  namespace :schema do
    namespace :cache do
      desc 'Dump schema cache for each tenant'
      task dump: :environment do
        paths = Apartment::SchemaCache.dump_all
        paths.each { |p| puts "Dumped: #{p}" }
      end
    end
  end
end
```

The Migrator does NOT auto-generate caches. Callers (rake tasks, `release.rb`, CI scripts) control when caching runs.

Note: The schema cache dump/load API varies across Rails versions. `connection.schema_cache.dump_to(path)` is the Rails 7.x+ pattern. `pool.schema_cache.load!(path)` is used for loading. Implementation should verify the exact API surface for Rails 7.2/8.0/8.1 (our CI matrix) and use version-conditional code if needed.

## PendingMigrationError

### Config

```ruby
Apartment.configure do |c|
  c.check_pending_migrations = true  # Boolean, default true
end
```

### Error Class

```ruby
# errors.rb
class PendingMigrationError < ApartmentError
  attr_reader :tenant

  def initialize(tenant = nil)
    @tenant = tenant
    super(
      tenant ? "Tenant '#{tenant}' has pending migrations. Run apartment:migrate to update."
             : 'Tenant has pending migrations. Run apartment:migrate to update.'
    )
  end
end
```

### Check Location

Inside `ConnectionHandling#connection_pool`, after `establish_connection`, gated behind three conditions:

```ruby
def check_pending_migrations?(pool)
  return false unless Apartment.config.check_pending_migrations
  return false unless defined?(Rails) && Rails.env.local?
  return false if Apartment::Current.migrating

  pool.migration_context.needs_migration?
end
```

### Migration Suppression

`Current.migrating` (boolean attribute on `Apartment::Current`) is set by the Migrator to suppress the check during migration. Without this, the Migrator would raise on the first tenant with pending migrations — the exact scenario it's trying to fix.

```ruby
# current.rb
class Current < ActiveSupport::CurrentAttributes
  attribute :tenant, :previous_tenant, :migrating
end

# migrator.rb
def run
  Apartment::Current.migrating = true
  # ... migration logic
ensure
  Apartment::Current.migrating = false
end
```

Note: `CurrentAttributes` is per-fiber. In parallel migration, each worker thread has its own `Current` instance. The `migrating` flag must be set inside each worker thread. Since `with_migration_role` wraps each `migrate_tenant`, and `migrate_tenant` runs inside the worker thread, we set `Current.migrating = true` at the `Migrator#run` level for the main thread (covering `migrate_primary`) and rely on the fact that `CurrentAttributes` auto-resets for new fibers/threads. The worker threads call `migrate_tenant`, which enters `Tenant.switch` → `ConnectionHandling#connection_pool`. At this point, `Current.migrating` in the worker thread is `nil` (default). This is a problem.

Solution: set `Current.migrating = true` inside `migrate_tenant`, before `Tenant.switch`:

```ruby
def migrate_tenant(tenant)
  start = monotonic_now
  Apartment::Current.migrating = true
  with_migration_role do
    Apartment::Tenant.switch(tenant) do
      # ...
    end
  end
rescue StandardError => e
  Result.new(tenant: tenant, status: :failed, duration: monotonic_now - start, error: e, versions_run: [])
ensure
  Apartment::Current.migrating = false
end
```

This ensures each worker thread has `migrating = true` in its own fiber-local `Current` before pool creation.

### Latency Note

The `needs_migration?` check queries `schema_migrations` — one database roundtrip per tenant on first pool creation. In development, this adds latency to the first request that touches a tenant. For apps with many tenants accessed in a single dev request, this could be noticeable. The check is development-only (`Rails.env.local?`) and runs once per tenant per boot (pool is cached), so the amortized cost is negligible. The config flag (`check_pending_migrations = false`) provides an escape hatch.

## Configuration

### New Config Keys

```ruby
Apartment.configure do |c|
  # Phase 5
  c.migration_role = :db_manager            # Symbol — connects_to role for DDL (default: nil)
  c.app_role = 'app_user'                   # String or callable — DML role to grant to (default: nil)
  c.schema_cache_per_tenant = false          # Boolean — per-tenant cache files (default: false)
  c.check_pending_migrations = true          # Boolean — raise in dev if pending (default: true)
end
```

### Validation

In `Config#validate!`:
- `migration_role`: must be nil or a Symbol
- `app_role`: must be nil, a String, or respond to `:call`
- `schema_cache_per_tenant`: must be boolean
- `check_pending_migrations`: must be boolean

### Freeze

`app_role` is frozen if it's a String (callables are not frozen — they may close over mutable state, and freezing a proc/lambda is a no-op anyway).

## Testing Strategy

### Unit Tests (no database required)

**ConnectionHandling role awareness:**
- Default role (`:writing`): pool key is `"tenant:writing"`, base config from primary
- Reading role: pool key is `"tenant:reading"`, base config from mock replica pool
- Custom role: pool key is `"tenant:db_manager"`, base config from mock db_manager pool
- Verify `super` is called to get the default pool for the current role
- Verify `base_config_override:` is passed to adapter

**Pool lifecycle (composite keys):**
- `PoolManager#remove_tenant`: removes all role variants for a tenant
- `PoolManager#evict_by_role`: removes all pools for a given role
- `AbstractAdapter#drop`: calls `remove_tenant`, deregisters all removed pools
- `Apartment.deregister_shard`: extracts role from composite pool key
- `PoolReaper`: default tenant guard matches `"default:*"` prefix pattern
- `PoolReaper`: evicts `"acme:db_manager"` but not `"public:writing"`

**Adapter base_config_override:**
- Each adapter: `resolve_connection_config` with and without `base_config:` keyword
- PostgresqlSchemaAdapter: merges search_path onto provided base
- Database adapters: merges database name onto provided base
- Sqlite3Adapter: merges file path onto provided base

**Migrator with_migration_role:**
- `migration_role: nil`: no `connected_to` wrapper
- `migration_role: :db_manager`: wraps in `connected_to(role: :db_manager)`
- Verify `Current.migrating` is set/cleared around each `migrate_tenant`
- Verify `with_migration_role` is called for both `migrate_primary` and `migrate_tenant`
- Thread safety: verify role context is per-thread (mock `connected_to_stack`)

**RBAC grants:**
- String `app_role`: verify adapter's `grant_privileges` called with tenant, connection, role_name
- Callable `app_role`: verify callable invoked with tenant, connection
- nil `app_role`: verify no grants
- PostgresqlSchemaAdapter: verify 6 SQL statements executed with correct quoting
- Mysql2Adapter: verify 1 SQL statement
- Sqlite3Adapter: verify no-op
- Grant ordering: verify grants run after `create_tenant`, before `import_schema`

**Schema cache:**
- `dump(tenant)`: verify `Tenant.switch` called, `schema_cache.dump_to` called with correct path
- `dump_all`: verify iterates tenants_provider
- `cache_path_for`: verify path format `db/schema_cache_<tenant>.yml`

**PendingMigrationError:**
- Check fires when: `check_pending_migrations = true`, `Rails.env.local? = true`, `Current.migrating = false`, `needs_migration? = true`
- Check suppressed when: config disabled, non-local env, `Current.migrating = true`, no pending migrations
- Error message includes tenant name

**Config validation:**
- `migration_role`: nil or Symbol accepted; other types rejected
- `app_role`: nil, String, callable accepted; other types rejected
- `schema_cache_per_tenant`: boolean only
- `check_pending_migrations`: boolean only

### Integration Tests (real databases)

**Role-aware connection (PostgreSQL):**
- Create tenant, switch under `:writing` role, verify pool uses primary config
- Switch under custom role with different config, verify pool uses that config
- Verify pool keys differ by role for same tenant
- Verify `prevent_writes: true` with `:reading` role propagates to tenant pool

**RBAC flow (PostgreSQL):**
- Configure `app_role: 'app_user'`, create tenant as db_manager
- Verify `app_user` can SELECT/INSERT/UPDATE/DELETE in the tenant schema
- Verify `app_user` can access tables created after initial grants (default privileges)
- Verify `app_user` cannot CREATE/DROP in the tenant schema

**Migrator with migration_role (PostgreSQL):**
- Configure `migration_role: :db_manager`, run Migrator
- Verify migrations ran with db_manager credentials (check schema ownership)
- Verify runtime pools (`:writing`) use app_user credentials

**PendingMigrationError (SQLite):**
- Create tenant, add migration, verify error raised on pool creation in local env
- Verify no error in production-like env
- Verify no error during Migrator run

**Schema cache (SQLite):**
- Generate cache, verify file exists at expected path
- Load cache on pool creation, verify schema cache is populated

## Files

```
lib/
├── apartment.rb                       # MODIFY — deregister_shard accepts composite pool key,
│                                      #          extracts role from key format "tenant:role"
lib/apartment/
├── current.rb                         # MODIFY — add :migrating attribute
├── config.rb                          # MODIFY — add migration_role, app_role,
│                                      #          schema_cache_per_tenant, check_pending_migrations
├── errors.rb                          # MODIFY — add PendingMigrationError
├── pool_manager.rb                    # MODIFY — add remove_tenant(tenant), evict_by_role(role)
├── pool_reaper.rb                     # MODIFY — default_tenant guard uses prefix match
├── patches/
│   └── connection_handling.rb         # MODIFY — role-aware base config, pool key format,
│                                      #          pending migration check, schema cache loading
├── migrator.rb                        # MODIFY — with_migration_role, Current.migrating,
│                                      #          evict_migration_pools after run
├── schema_cache.rb                    # NEW    — dump/dump_all/cache_path_for
├── adapters/
│   ├── abstract_adapter.rb           # MODIFY — base_config_override: keyword,
│   │                                 #          grant_tenant_privileges dispatch,
│   │                                 #          drop uses remove_tenant for all roles
│   ├── postgresql_schema_adapter.rb  # MODIFY — resolve_connection_config base_config:,
│   │                                 #          grant_privileges (6 SQL)
│   ├── postgresql_database_adapter.rb # MODIFY — resolve_connection_config base_config:,
│   │                                 #          grant_privileges (5 SQL, see note)
│   ├── mysql2_adapter.rb             # MODIFY — resolve_connection_config base_config:,
│   │                                 #          grant_privileges (1 SQL)
│   ├── trilogy_adapter.rb            # MODIFY — inherits from Mysql2Adapter (may need no change)
│   └── sqlite3_adapter.rb           # MODIFY — resolve_connection_config base_config:
├── tasks/
│   └── v4.rake                       # MODIFY — add apartment:schema:cache:dump

spec/unit/
├── connection_handling_role_spec.rb   # NEW — role-aware pool resolution
├── migrator_role_spec.rb             # NEW — with_migration_role, Current.migrating
├── rbac_grants_spec.rb               # NEW — app_role grant logic per adapter
├── schema_cache_spec.rb              # NEW — dump/load/path
├── pending_migration_spec.rb         # NEW — check conditions and suppression

spec/integration/v4/
├── role_aware_connection_spec.rb     # NEW — PG role-based pool resolution
├── rbac_grants_spec.rb               # NEW — PG grant verification with real roles
├── migrator_rbac_spec.rb            # NEW — Migrator with migration_role
```

## Out of Scope

- Thor CLI commands (Phase 6)
- Automatic replica switching middleware (Rails provides this; Apartment doesn't need its own)
- Per-tenant connection configs / multi-shard support beyond what `connects_to` provides
- `PoolManager#evict_by_role` ~~(operational convenience; deferred unless needed)~~ — promoted to in-scope; used by `Migrator#evict_migration_pools`
- `ARTENANT=` single-tenant targeting (future)
