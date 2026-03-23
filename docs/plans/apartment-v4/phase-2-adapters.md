# Phase 2: Adapters & Tenant API — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the database engine — adapters that create/drop/switch tenants, the public `Apartment::Tenant` API, and ActiveRecord connection handling patches. End state: `Apartment::Tenant.switch("acme") { User.count }` works end-to-end against real PostgreSQL and MySQL databases.

**Architecture:** v4 eliminates v3's adapter-per-thread pattern. Instead, database differences are expressed as configuration strategies (how to build a tenant-specific connection config). The `Tenant` module sets `Current.tenant`, and `ConnectionHandling` patches resolve the right pool. Adapters handle lifecycle operations (create/drop schema or database) but not switching — switching is a pool lookup.

**Tech Stack:** Ruby 3.3+, ActiveRecord 7.2+, PostgreSQL 12+, MySQL 5.7+/8.0+, SQLite3, RSpec

**Spec:** [`docs/designs/apartment-v4.md`](../../designs/apartment-v4.md)

**Depends on:** Phase 1 (Config, Current, PoolManager, PoolReaper, Errors, Instrumentation)

---

## Architectural Overview

### How v4 switching works (vs v3)

```
v3: Tenant.switch("acme")
    → adapter.switch!("acme")
    → SET search_path TO acme,public  (PostgreSQL)
    → or USE acme_db                   (MySQL)
    → Thread.current[:apartment_adapter].current = "acme"

v4: Tenant.switch("acme") { ... }
    → Current.tenant = "acme"
    → ActiveRecord queries resolve connection_pool via ConnectionHandling patch
    → Pool lookup in PoolManager (cached Concurrent::Map)
    → Pool created lazily with tenant-specific config if absent
    → No SQL switching commands at all
```

### Key components and their responsibilities

```
Apartment::Tenant              Public API (switch, current, reset, create, drop, etc.)
    |
    v
Apartment::Current             Fiber-safe tenant context (from Phase 1)
    |
    v
Apartment::Patches::           Prepended on AR::Base — intercepts connection_pool
ConnectionHandling             to return tenant-specific pool
    |
    v
Apartment::PoolManager         Caches pools by tenant key (from Phase 1)
    |
    v
Apartment::Adapters::          Lifecycle operations: create/drop schema or database
AbstractAdapter                Resolves connection config per strategy
    |
    +-- PostgreSQLSchemaAdapter     CREATE SCHEMA / DROP SCHEMA
    +-- PostgreSQLDatabaseAdapter   CREATE DATABASE / DROP DATABASE (PostgreSQL)
    +-- MySQL2Adapter               CREATE DATABASE / DROP DATABASE (MySQL)
    +-- TrilogyAdapter              Same as MySQL2, different driver
    +-- SQLite3Adapter              File creation/deletion
```

---

## File Map

### New files (create)

| File | Responsibility |
|------|---------------|
| `lib/apartment/tenant.rb` | Public API module (replaces v3 tenant.rb) |
| `lib/apartment/adapters/abstract_adapter.rb` | Base adapter with lifecycle, callbacks, excluded models |
| `lib/apartment/adapters/postgresql_schema_adapter.rb` | Schema-per-tenant: CREATE/DROP SCHEMA, resolve_connection_config |
| `lib/apartment/adapters/postgresql_database_adapter.rb` | Database-per-tenant on PostgreSQL |
| `lib/apartment/adapters/mysql2_adapter.rb` | Database-per-tenant on MySQL (mysql2 driver) |
| `lib/apartment/adapters/trilogy_adapter.rb` | Database-per-tenant on MySQL (trilogy driver) |
| `lib/apartment/adapters/sqlite3_adapter.rb` | File-per-tenant |
| `lib/apartment/patches/connection_handling.rb` | AR::Base prepend for tenant-aware pool resolution |
| `spec/unit/tenant_spec.rb` | Public API tests (mocked adapters) |
| `spec/unit/adapters/abstract_adapter_spec.rb` | Adapter contract tests |
| `spec/unit/adapters/postgresql_schema_adapter_spec.rb` | PostgreSQL schema tests |
| `spec/unit/adapters/postgresql_database_adapter_spec.rb` | PostgreSQL database tests |
| `spec/unit/adapters/mysql2_adapter_spec.rb` | MySQL tests |
| `spec/unit/patches/connection_handling_spec.rb` | AR patching tests |
| `spec/integration/tenant_switching_spec.rb` | End-to-end switching with real DB |
| `spec/integration/tenant_lifecycle_spec.rb` | Create/drop with real DB |
| `spec/integration/excluded_models_spec.rb` | Excluded model isolation |

### Modified files

| File | Change |
|------|--------|
| `lib/apartment.rb` | Add adapter accessor, adapter factory, update Zeitwerk ignores |
| `lib/apartment/config.rb` | Add `adapter` reader (lazily resolved from strategy + database.yml) |
| `Gemfile` | Add database gems as development dependencies |

### Removed v3 files (replaced)

| File | Replacement |
|------|-------------|
| `lib/apartment/tenant.rb` | New v4 tenant.rb |
| `lib/apartment/adapters/abstract_adapter.rb` | New v4 abstract_adapter.rb |
| `lib/apartment/adapters/postgresql_adapter.rb` | Split into postgresql_schema_adapter.rb + postgresql_database_adapter.rb |
| `lib/apartment/adapters/mysql2_adapter.rb` | New v4 mysql2_adapter.rb |
| `lib/apartment/adapters/trilogy_adapter.rb` | New v4 trilogy_adapter.rb |
| `lib/apartment/adapters/sqlite3_adapter.rb` | New v4 sqlite3_adapter.rb |
| `lib/apartment/adapters/abstract_jdbc_adapter.rb` | Dropped (JDBC not supported in v4) |
| `lib/apartment/adapters/jdbc_postgresql_adapter.rb` | Dropped |
| `lib/apartment/adapters/jdbc_mysql_adapter.rb` | Dropped |
| `lib/apartment/adapters/postgis_adapter.rb` | Dropped (use PostgreSQLSchemaAdapter with PostGIS) |
| `lib/apartment/model.rb` | Replaced by excluded model handling in abstract_adapter |
| `lib/apartment/active_record/` | Replaced by patches/connection_handling.rb |

---

## Task 1: Apartment::Tenant public API

**Files:**
- Replace: `lib/apartment/tenant.rb`
- Create: `spec/unit/tenant_spec.rb`
- Modify: `lib/apartment.rb` (update Zeitwerk ignores, add adapter accessor)

This task builds the public API with stubbed adapter delegation. No real database operations yet — that comes in later tasks.

### Implementation

`lib/apartment/tenant.rb`:

```ruby
# frozen_string_literal: true

module Apartment
  module Tenant
    class << self
      # Switch to a tenant for the duration of the block.
      # Guaranteed cleanup via ensure — tenant context is always restored.
      def switch(tenant)
        raise ArgumentError, 'Apartment::Tenant.switch requires a block' unless block_given?

        previous = Current.tenant
        Current.tenant = tenant
        Current.previous_tenant = previous
        yield
      ensure
        Current.tenant = previous
        Current.previous_tenant = nil
      end

      # Direct switch without block. Discouraged — prefer switch with block.
      def switch!(tenant)
        Current.previous_tenant = Current.tenant
        Current.tenant = tenant
      end

      # Current tenant name.
      def current
        Current.tenant || Apartment.config&.default_tenant
      end

      # Reset to default tenant.
      def reset
        switch!(Apartment.config&.default_tenant)
      end

      # Initialize: process excluded models, set up default tenant.
      def init
        adapter.process_excluded_models
      end

      # Delegate lifecycle operations to the adapter.
      def create(tenant)
        adapter.create(tenant)
      end

      def drop(tenant)
        adapter.drop(tenant)
      end

      def migrate(tenant, version = nil)
        adapter.migrate(tenant, version)
      end

      def seed(tenant)
        adapter.seed(tenant)
      end

      # Pool stats delegated to pool_manager.
      def pool_stats
        Apartment.pool_manager&.stats || {}
      end

      private

      def adapter
        Apartment.adapter
      end
    end
  end
end
```

### Tests

`spec/unit/tenant_spec.rb` should test:
- `switch` sets/restores Current.tenant and Current.previous_tenant
- `switch` restores tenant on exception
- `switch` requires a block (ArgumentError)
- `switch!` sets tenant without block
- `current` returns Current.tenant or default_tenant
- `reset` sets tenant to default
- `create`, `drop`, `migrate`, `seed` delegate to adapter

Use mocked adapter for lifecycle delegation tests.

### apartment.rb updates

- Remove `tenant.rb` from Zeitwerk ignore list (it's being replaced)
- Add `adapter` accessor and factory method
- Remove v3 adapter files from ignore list, replace with new adapter directory handling

---

## Task 2: Patches::ConnectionHandling

**Files:**
- Create: `lib/apartment/patches/connection_handling.rb`
- Create: `spec/unit/patches/connection_handling_spec.rb`

This is the most architecturally sensitive component — it patches ActiveRecord::Base to make pool lookups tenant-aware.

### Implementation

`lib/apartment/patches/connection_handling.rb`:

```ruby
# frozen_string_literal: true

module Apartment
  module Patches
    module ConnectionHandling
      # Override connection_pool to return a tenant-specific pool.
      # When Current.tenant is set, looks up (or lazily creates) a pool
      # with tenant-specific connection config.
      def connection_pool
        tenant = Apartment::Current.tenant
        default = Apartment.config&.default_tenant

        # No tenant context or default tenant — use Rails' normal behavior
        return super if tenant.nil? || tenant == default

        pool_key = "#{connection_specification_name}[#{tenant}]"

        Apartment.pool_manager.fetch_or_create(pool_key) do
          # Ask the adapter to resolve the connection config for this tenant
          config = Apartment.adapter.resolve_connection_config(tenant)

          # Establish a new connection pool with tenant-specific config
          # This registers the pool with ActiveRecord's ConnectionHandler
          resolver = ActiveRecord::ConnectionAdapters::ConnectionSpecification::Resolver.new({})
          # ... (Rails version-specific pool creation)
          #
          # The exact mechanism varies by Rails version (7.2 vs 8.0 vs 8.1).
          # Implementation will use establish_connection with a tenant-qualified
          # config name to create the pool within AR's handler.
        end
      end
    end
  end
end
```

**Critical implementation notes:**
- Must work across Rails 7.2, 8.0, and 8.1
- ActiveRecord's pool creation API changed between versions — need version gates or duck-typing
- The pool must be registered with AR's ConnectionHandler so `database_cleaner`, `strong_migrations`, etc. work
- `connection_specification_name` must be overridden to include tenant for proper pool keying

### Tests

Test with a real SQLite3 database (lightweight, no external service needed):
- Default tenant returns super's pool
- Tenant set returns tenant-specific pool
- Same tenant returns same pool (cached)
- Different tenants return different pools
- Pool is registered with AR's ConnectionHandler

---

## Task 3: AbstractAdapter

**Files:**
- Create: `lib/apartment/adapters/abstract_adapter.rb`
- Create: `spec/unit/adapters/abstract_adapter_spec.rb`

### Implementation

```ruby
# frozen_string_literal: true

module Apartment
  module Adapters
    class AbstractAdapter
      include ActiveSupport::Callbacks
      define_callbacks :create, :switch

      attr_reader :config

      def initialize(config)
        @config = config
      end

      # Resolve a tenant-specific connection config hash.
      # Subclasses override to set strategy-specific keys.
      def resolve_connection_config(tenant)
        raise NotImplementedError
      end

      # Create a new tenant (schema or database).
      def create(tenant)
        run_callbacks :create do
          create_tenant(tenant)
          Instrumentation.instrument(:create, tenant: tenant)
        end
      end

      # Drop a tenant.
      def drop(tenant)
        drop_tenant(tenant)
        # Remove cached pool
        pool_key = "ActiveRecord::Base[#{tenant}]"
        pool = Apartment.pool_manager.remove(pool_key)
        pool&.disconnect! if pool.respond_to?(:disconnect!)
        Instrumentation.instrument(:drop, tenant: tenant)
      end

      # Run migrations for a tenant.
      def migrate(tenant, version = nil)
        Apartment::Tenant.switch(tenant) do
          ActiveRecord::Base.connection_pool.migration_context.migrate(version)
        end
      end

      # Run seeds for a tenant.
      def seed(tenant)
        Apartment::Tenant.switch(tenant) do
          seed_file = Apartment.config.seed_data_file
          load(seed_file) if seed_file && File.exist?(seed_file)
        end
      end

      # Process excluded models — establish separate connections pinned to default tenant.
      def process_excluded_models
        default_config = resolve_connection_config(
          Apartment.config.default_tenant
        )

        Apartment.config.excluded_models.each do |model_name|
          klass = model_name.constantize
          klass.establish_connection(default_config)
        end
      end

      # Environmentify a tenant name based on config.
      def environmentify(tenant)
        case Apartment.config.environmentify_strategy
        when :prepend
          "#{Rails.env}_#{tenant}"
        when :append
          "#{tenant}_#{Rails.env}"
        when nil
          tenant.to_s
        else
          # Callable
          Apartment.config.environmentify_strategy.call(tenant)
        end
      end

      # Default tenant from config.
      def default_tenant
        Apartment.config.default_tenant
      end

      protected

      def create_tenant(tenant)
        raise NotImplementedError
      end

      def drop_tenant(tenant)
        raise NotImplementedError
      end
    end
  end
end
```

### Tests

- `resolve_connection_config` raises NotImplementedError (abstract)
- `create` runs callbacks and instruments
- `drop` removes pool from PoolManager and instruments
- `migrate` switches tenant and runs migrations (mocked)
- `seed` switches tenant and loads seed file (mocked)
- `process_excluded_models` establishes connections for each model
- `environmentify` handles :prepend, :append, nil, and callable

---

## Task 4: PostgreSQLSchemaAdapter

**Files:**
- Create: `lib/apartment/adapters/postgresql_schema_adapter.rb`
- Create: `spec/unit/adapters/postgresql_schema_adapter_spec.rb`

### Implementation

```ruby
# frozen_string_literal: true

module Apartment
  module Adapters
    class PostgreSQLSchemaAdapter < AbstractAdapter
      def resolve_connection_config(tenant)
        pg_config = Apartment.config.postgres_config
        persistent = pg_config&.persistent_schemas || []
        search_path = [tenant, *persistent].join(",")

        base_config.merge("schema_search_path" => search_path)
      end

      protected

      def create_tenant(tenant)
        # Use a connection from the default pool to create the schema
        ActiveRecord::Base.connection.execute(
          "CREATE SCHEMA #{ActiveRecord::Base.connection.quote_table_name(tenant)}"
        )
      end

      def drop_tenant(tenant)
        ActiveRecord::Base.connection.execute(
          "DROP SCHEMA #{ActiveRecord::Base.connection.quote_table_name(tenant)} CASCADE"
        )
      end

      private

      def base_config
        Apartment.config.connection_db_config&.configuration_hash&.stringify_keys ||
          ActiveRecord::Base.connection_db_config.configuration_hash.stringify_keys
      end
    end
  end
end
```

### Tests (require real PostgreSQL)

- `resolve_connection_config` returns config with `schema_search_path`
- `resolve_connection_config` includes persistent_schemas
- `create_tenant` executes `CREATE SCHEMA`
- `drop_tenant` executes `DROP SCHEMA CASCADE`
- Full lifecycle: create → switch → verify isolation → drop

---

## Task 5: PostgreSQLDatabaseAdapter

**Files:**
- Create: `lib/apartment/adapters/postgresql_database_adapter.rb`
- Create: `spec/unit/adapters/postgresql_database_adapter_spec.rb`

### Implementation

```ruby
# frozen_string_literal: true

module Apartment
  module Adapters
    class PostgreSQLDatabaseAdapter < AbstractAdapter
      def resolve_connection_config(tenant)
        base_config.merge("database" => environmentify(tenant))
      end

      protected

      def create_tenant(tenant)
        db_name = environmentify(tenant)
        # Connect to template1 or default DB for CREATE DATABASE
        ActiveRecord::Base.connection.execute(
          "CREATE DATABASE #{ActiveRecord::Base.connection.quote_table_name(db_name)}"
        )
      end

      def drop_tenant(tenant)
        db_name = environmentify(tenant)
        ActiveRecord::Base.connection.execute(
          "DROP DATABASE IF EXISTS #{ActiveRecord::Base.connection.quote_table_name(db_name)}"
        )
      end

      private

      def base_config
        ActiveRecord::Base.connection_db_config.configuration_hash.stringify_keys
      end
    end
  end
end
```

### Tests (require real PostgreSQL)

- `resolve_connection_config` returns config with `database` key
- `create_tenant` executes `CREATE DATABASE`
- `drop_tenant` executes `DROP DATABASE`

---

## Task 6: MySQL2Adapter and TrilogyAdapter

**Files:**
- Create: `lib/apartment/adapters/mysql2_adapter.rb`
- Create: `lib/apartment/adapters/trilogy_adapter.rb`
- Create: `spec/unit/adapters/mysql2_adapter_spec.rb`

### Implementation

`mysql2_adapter.rb`:
```ruby
# frozen_string_literal: true

module Apartment
  module Adapters
    class MySQL2Adapter < AbstractAdapter
      def resolve_connection_config(tenant)
        base_config.merge("database" => environmentify(tenant))
      end

      protected

      def create_tenant(tenant)
        db_name = environmentify(tenant)
        ActiveRecord::Base.connection.execute(
          "CREATE DATABASE #{ActiveRecord::Base.connection.quote_table_name(db_name)}"
        )
      end

      def drop_tenant(tenant)
        db_name = environmentify(tenant)
        ActiveRecord::Base.connection.execute(
          "DROP DATABASE IF EXISTS #{ActiveRecord::Base.connection.quote_table_name(db_name)}"
        )
      end

      private

      def base_config
        ActiveRecord::Base.connection_db_config.configuration_hash.stringify_keys
      end
    end
  end
end
```

`trilogy_adapter.rb`:
```ruby
# frozen_string_literal: true

module Apartment
  module Adapters
    class TrilogyAdapter < MySQL2Adapter
      # Same behavior as MySQL2Adapter — Trilogy is a compatible MySQL driver.
      # Exception handling differences (Trilogy::Error vs Mysql2::Error)
      # are handled at the connection pool level, not the adapter.
    end
  end
end
```

---

## Task 7: SQLite3Adapter

**Files:**
- Create: `lib/apartment/adapters/sqlite3_adapter.rb`
- Create: `spec/unit/adapters/sqlite3_adapter_spec.rb`

### Implementation

```ruby
# frozen_string_literal: true

module Apartment
  module Adapters
    class SQLite3Adapter < AbstractAdapter
      def resolve_connection_config(tenant)
        base_config.merge("database" => database_file(tenant))
      end

      protected

      def create_tenant(tenant)
        # SQLite creates the file on first connection — just verify the dir exists
        FileUtils.mkdir_p(File.dirname(database_file(tenant)))
      end

      def drop_tenant(tenant)
        file = database_file(tenant)
        File.delete(file) if File.exist?(file)
      end

      private

      def database_file(tenant)
        db_dir = File.dirname(base_config["database"] || "db/#{tenant}.sqlite3")
        File.join(db_dir, "#{environmentify(tenant)}.sqlite3")
      end

      def base_config
        ActiveRecord::Base.connection_db_config.configuration_hash.stringify_keys
      end
    end
  end
end
```

---

## Task 8: Adapter factory and apartment.rb wiring

**Files:**
- Modify: `lib/apartment.rb`
- Modify: `lib/apartment/config.rb`

### Implementation

Add to `lib/apartment.rb`:
```ruby
def adapter
  @adapter ||= build_adapter
end

private

def build_adapter
  strategy = config.tenant_strategy
  db_adapter = detect_database_adapter

  klass = case strategy
          when :schema
            require_relative 'apartment/adapters/postgresql_schema_adapter'
            Adapters::PostgreSQLSchemaAdapter
          when :database_name
            case db_adapter
            when /postgresql/, /postgis/
              require_relative 'apartment/adapters/postgresql_database_adapter'
              Adapters::PostgreSQLDatabaseAdapter
            when /mysql2/
              require_relative 'apartment/adapters/mysql2_adapter'
              Adapters::MySQL2Adapter
            when /trilogy/
              require_relative 'apartment/adapters/trilogy_adapter'
              Adapters::TrilogyAdapter
            when /sqlite/
              require_relative 'apartment/adapters/sqlite3_adapter'
              Adapters::SQLite3Adapter
            else
              raise AdapterNotFound, "No adapter for database: #{db_adapter}"
            end
          else
            raise AdapterNotFound, "Strategy #{strategy} not yet implemented"
          end

  klass.new(ActiveRecord::Base.connection_db_config.configuration_hash)
end

def detect_database_adapter
  ActiveRecord::Base.connection_db_config.adapter
end
```

Update `clear_config` to also clear the adapter:
```ruby
def clear_config
  PoolReaper.stop
  @pool_manager&.clear
  @config = nil
  @pool_manager = nil
  @adapter = nil
end
```

### Zeitwerk updates

Remove v3 adapter files from ignore list (they're being replaced):
- Remove `lib/apartment/adapters` from ignore
- Remove `lib/apartment/tenant.rb` from ignore
- Remove `lib/apartment/model.rb` from ignore
- Remove `lib/apartment/active_record` from ignore
- Delete v3 files that are being replaced
- Keep ignoring: `railtie`, `deprecation`, `log_subscriber`, `console`, `custom_console`, `migrator`, `patches` (v3 patches dir)

---

## Task 9: ConnectionHandling implementation (Rails 7.2/8.0/8.1)

**Files:**
- Create: `lib/apartment/patches/connection_handling.rb`
- Create: `spec/unit/patches/connection_handling_spec.rb`

This is the most complex task. The implementation must work across Rails 7.2, 8.0, and 8.1, which have different pool management APIs.

### Implementation approach

Use ActiveRecord's public `ConnectionHandler#establish_connection` API (stable across Rails 7.2-8.1). This method accepts `config`, `owner_name:`, `role:`, and `shard:` parameters and returns a connection pool. Key behavior:

- **Rails 7.2+**: `establish_connection` is lazy — pool is created but no connection established until first query. This aligns perfectly with our lazy pool creation model.
- **`owner_name:`** — We use a tenant-qualified name (e.g., `"apartment_acme"`) to create tenant-specific pools that are tracked by AR's handler.
- **Idempotent**: If called with the same config, returns the existing pool (no duplicate creation).

```ruby
# frozen_string_literal: true

module Apartment
  module Patches
    module ConnectionHandling
      def connection_pool
        tenant = Apartment::Current.tenant
        default = Apartment.config&.default_tenant

        return super if tenant.nil? || tenant == default
        return super unless Apartment.pool_manager

        pool_key = tenant.to_s

        Apartment.pool_manager.fetch_or_create(pool_key) do
          config = Apartment.adapter.resolve_connection_config(tenant)

          # Use AR's public establish_connection API.
          # owner_name creates a separate pool namespace for this tenant.
          # Rails 7.2+ lazily connects (no actual DB connection until first query).
          handler = ActiveRecord::Base.connection_handler
          db_config = ActiveRecord::DatabaseConfigurations::HashConfig.new(
            Rails.env, "apartment_#{tenant}", config
          )

          handler.establish_connection(
            db_config,
            owner_name: ActiveRecord::Base,
            role: ActiveRecord::Base.current_role,
            shard: tenant.to_sym
          )
        end
      end
    end
  end
end
```

**Why `shard: tenant.to_sym`**: Using the tenant as a shard identifier within AR's handler leverages Rails' native multi-database infrastructure. Each tenant gets its own pool keyed by `(owner_name, role, shard)`. This is the same mechanism Rails uses for `connects_to shards: { ... }`, so it integrates cleanly with existing Rails tooling.

**Alternative considered**: Using `owner_name: "apartment_#{tenant}"` (unique owner per tenant). This works but creates separate pool managers per tenant in AR's handler, which is heavier than using shards. The shard approach is more aligned with Rails' intent.

**Note on pool eviction**: When the PoolReaper evicts a tenant pool, it must call `handler.remove_connection_pool(shard: tenant.to_sym)` to deregister from AR's handler, in addition to removing from our PoolManager.

### Tests (SQLite3 for speed, PostgreSQL for integration)

- Verify pool resolution for default tenant (returns super)
- Verify pool resolution for active tenant (returns tenant pool)
- Verify pool caching (same pool for same tenant)
- Verify different tenants get different pools
- Verify pool is usable (can execute queries)
- Verify pool is registered with AR's ConnectionHandler
- Verify pool is lazy (no connection until first query, per Rails 7.2+ behavior)

---

## Task 10: Excluded models processing

**Files:**
- Modify: `lib/apartment/adapters/abstract_adapter.rb`
- Create: `spec/unit/excluded_models_spec.rb`

### Implementation

Excluded models get `establish_connection` with the default tenant's config, pinning them to the shared schema/database. Their table names are prefixed with the default schema/database name for PostgreSQL schema strategy.

```ruby
def process_excluded_models
  return if Apartment.config.excluded_models.empty?

  default_config = resolve_connection_config(default_tenant)

  Apartment.config.excluded_models.each do |model_name|
    klass = model_name.constantize

    # Establish a separate connection pinned to default tenant
    klass.establish_connection(default_config)

    # For PostgreSQL schema strategy, prefix table names
    if Apartment.config.tenant_strategy == :schema
      table = klass.table_name.split('.').last  # Strip existing prefix if any
      klass.table_name = "#{default_tenant}.#{table}"
    end
  end
end
```

### Tests

- Excluded models connect to default tenant
- Excluded model queries work regardless of current tenant
- PostgreSQL schema strategy prefixes table names
- Database strategy does not prefix table names

---

## Task 11: Integration tests with real databases

**Files:**
- Create: `spec/integration/tenant_switching_spec.rb`
- Create: `spec/integration/tenant_lifecycle_spec.rb`
- Create: `spec/integration/excluded_models_spec.rb`
- Create: `spec/support/database_helper.rb`
- Modify: `Gemfile` (add database gems)

### Database helper

```ruby
# spec/support/database_helper.rb
module DatabaseHelper
  def self.database_engine
    ENV.fetch('DB', 'sqlite3')
  end

  def self.postgresql?
    database_engine == 'postgresql'
  end

  def self.mysql?
    database_engine == 'mysql'
  end

  def self.sqlite?
    database_engine == 'sqlite3'
  end
end
```

### Integration test: tenant switching

```ruby
# spec/integration/tenant_switching_spec.rb
RSpec.describe 'Tenant switching', :integration do
  before(:all) do
    Apartment.configure do |config|
      config.tenant_strategy = strategy_for_engine
      config.tenants_provider = -> { %w[tenant_a tenant_b] }
      config.default_tenant = default_for_engine
    end
    Apartment::Tenant.create('tenant_a')
    Apartment::Tenant.create('tenant_b')
  end

  after(:all) do
    Apartment::Tenant.drop('tenant_a')
    Apartment::Tenant.drop('tenant_b')
    Apartment.clear_config
  end

  it 'isolates data between tenants' do
    Apartment::Tenant.switch('tenant_a') do
      User.create!(name: 'Alice')
    end

    Apartment::Tenant.switch('tenant_b') do
      expect(User.count).to eq(0)
    end

    Apartment::Tenant.switch('tenant_a') do
      expect(User.count).to eq(1)
    end
  end

  it 'restores tenant on exception' do
    expect {
      Apartment::Tenant.switch('tenant_a') do
        raise 'boom'
      end
    }.to raise_error('boom')

    expect(Apartment::Tenant.current).to eq(default_for_engine)
  end

  it 'supports nested switching' do
    Apartment::Tenant.switch('tenant_a') do
      Apartment::Tenant.switch('tenant_b') do
        expect(Apartment::Tenant.current).to eq('tenant_b')
      end
      expect(Apartment::Tenant.current).to eq('tenant_a')
    end
  end
end
```

### Gemfile updates

```ruby
group :development, :test do
  gem 'pg', '>= 1.5'
  gem 'mysql2', '>= 0.5'
  gem 'trilogy', '>= 2.7'
  gem 'sqlite3', '>= 2.0'
end
```

---

## Task 12: Delete v3 adapter files and clean up

**Files:**
- Delete: `lib/apartment/adapters/abstract_jdbc_adapter.rb`
- Delete: `lib/apartment/adapters/jdbc_postgresql_adapter.rb`
- Delete: `lib/apartment/adapters/jdbc_mysql_adapter.rb`
- Delete: `lib/apartment/adapters/postgis_adapter.rb`
- Delete: `lib/apartment/model.rb`
- Delete: `lib/apartment/active_record/` (entire directory)
- Update: `lib/apartment.rb` (clean up Zeitwerk ignores)

### Verification

After deletion:
- `bundle exec rspec spec/unit/` passes
- `DB=sqlite3 bundle exec rspec spec/integration/` passes
- `DB=postgresql bundle exec rspec spec/integration/` passes (if PG available)
- Zeitwerk eager load: `bundle exec ruby -e "require 'apartment'; Zeitwerk::Loader.eager_load_all"`

---

## Sub-Phases

Phase 2 is split into sub-phases that can be executed as separate PRs on the same branch (`man/v4-adapters`). Each sub-phase produces a working, testable increment.

### Phase 2.1: Core Structure (Tasks 1, 3, 8)

**Branch:** `man/v4-adapters` (first PR)

**What:** The skeleton everything plugs into.
- Task 1: `Apartment::Tenant` public API (switch, current, reset, create/drop delegation)
- Task 3: `Apartment::Adapters::AbstractAdapter` (lifecycle, callbacks, resolve_connection_config interface)
- Task 8: Adapter factory in `Apartment.adapter` + Zeitwerk wiring

**Produces:** Working `Apartment::Tenant.switch("acme") { ... }` with Current, and `Apartment.adapter` resolving the right adapter class. No real database operations yet — adapter subclasses come next.

**Tests:** All unit tests with mocked adapters. No database required.

**Estimated scope:** ~6 files to create/modify, ~40 test examples

### Phase 2.2: Database Adapters (Tasks 4, 5, 6, 7)

**What:** Concrete adapter implementations. These are independent of each other.
- Task 4: `PostgreSQLSchemaAdapter` (CREATE/DROP SCHEMA, schema_search_path)
- Task 5: `PostgreSQLDatabaseAdapter` (CREATE/DROP DATABASE on PostgreSQL)
- Task 6: `MySQL2Adapter` + `TrilogyAdapter` (CREATE/DROP DATABASE on MySQL)
- Task 7: `SQLite3Adapter` (file-per-tenant)

**Produces:** All five adapter classes implemented with `resolve_connection_config`, `create_tenant`, `drop_tenant`.

**Tests:** Unit tests with mocked database connections for config resolution. Database-specific lifecycle tests can use real DB if available, SQLite3 as fallback.

**Estimated scope:** ~5 files to create, ~30 test examples

### Phase 2.3: Connection Handling & Pool Wiring (Tasks 2, 9)

**What:** The architecturally complex piece — ActiveRecord patching.
- Task 2: `Apartment::Patches::ConnectionHandling` module definition
- Task 9: Full implementation using AR's `establish_connection` with shard-based pool keying

**Produces:** `ActiveRecord::Base.connection_pool` returns tenant-specific pools when `Current.tenant` is set. Pools are lazily created and cached in PoolManager.

**Tests:** Tests with real SQLite3 database proving pool isolation. This is where the pool-per-tenant architecture is validated.

**Estimated scope:** ~2 files to create, ~15 test examples. High complexity — most time spent here.

### Phase 2.4: Excluded Models & Integration (Tasks 10, 11)

**What:** Cross-cutting validation.
- Task 10: Excluded model processing (establish_connection pinned to default)
- Task 11: End-to-end integration tests with real PostgreSQL, MySQL, SQLite

**Produces:** Full working system. `Apartment::Tenant.switch("acme") { User.count }` works against real databases. Excluded models bypass tenant switching.

**Tests:** Integration tests requiring database services. Gemfile updated with `pg`, `mysql2`, `trilogy`, `sqlite3`.

**Estimated scope:** ~5 files, ~25 test examples

### Phase 2.5: Cleanup (Task 12)

**What:** Delete replaced v3 files, clean up Zeitwerk ignores.

**Produces:** Clean `lib/apartment/adapters/` directory with only v4 files. Zeitwerk loads without warnings.

**Estimated scope:** File deletions, Zeitwerk cleanup, verification pass

---

## Sub-Phase Dependency Graph

```
Phase 2.1: Core Structure (Tasks 1, 3, 8)
    |
    +---------------------------+
    |                           |
Phase 2.2: Database Adapters    Phase 2.3: Connection Handling
(Tasks 4, 5, 6, 7)             (Tasks 2, 9)
    |                           |
    +---------------------------+
    |
Phase 2.4: Excluded Models & Integration (Tasks 10, 11)
    |
Phase 2.5: Cleanup (Task 12)
```

Phase 2.2 and 2.3 are independent and can be done in either order. Phase 2.3 is more complex and architecturally risky — may benefit from being done first to surface issues early.

---

## Completion Checklist

- [ ] All unit specs pass: `bundle exec rspec spec/unit/`
- [ ] Integration specs pass with SQLite: `DB=sqlite3 bundle exec rspec spec/integration/`
- [ ] Integration specs pass with PostgreSQL: `DB=postgresql bundle exec rspec spec/integration/`
- [ ] Integration specs pass with MySQL: `DB=mysql bundle exec rspec spec/integration/`
- [ ] Zeitwerk eager load clean: `bundle exec ruby -e "require 'apartment'; Zeitwerk::Loader.eager_load_all"`
- [ ] No v3 adapter files remain (except those still needed by later phases)
- [ ] `Apartment::Tenant.switch("acme") { User.count }` works end-to-end
- [ ] All commits on branch, ready for PR

## Notes from Phase 1 review (deferred to Phase 2)

These items were flagged during Phase 1 review and should be addressed during this phase:

- [x] Freeze Config after validate! (now that adapters consume it) — done in Phase 2.1
- [ ] Consider converting PoolReaper from class singleton to instance — address in Phase 2.3
- [x] Add switch/reset methods to Current — decided against: Tenant.switch/reset use Current attributes directly; Current stays thin (just attributes)
- [ ] Resolve any remaining persistent_schemas usage (now only on PostgreSQLConfig) — address in Phase 2.2

## Notes from Phase 2.1 review (deferred to later sub-phases)

Flagged during comprehensive PR review of Phase 2.1. Categorized by target sub-phase.

### Phase 2.2 (Database Adapters)

- [ ] Adapter factory routing tests assert LoadError/NameError for missing v4 files — rewrite to use stub pattern when concrete adapters land
- [ ] `environmentify` does not guard against `Rails` being undefined — relevant when concrete adapters call it outside Rails context

### Phase 2.3 (Connection Handling & Pool Wiring)

- [ ] PoolReaper evict_idle/evict_lru do not call `disconnect!` on evicted pools — pools rely on GC. Add explicit disconnect when pool wiring is implemented
- [ ] `configure` teardown sequence not protected — if `PoolReaper.stop` raises after validation passes, system is half-torn-down. Wrap in begin/rescue

### Phase 2.4 (Excluded Models & Integration)

- [ ] `process_excluded_models` — wrap `constantize` NameError with `ConfigurationError` for clear boot-time error messages
- [ ] `seed` method — raise when configured seed file doesn't exist instead of silent no-op
- [ ] `AbstractAdapter#drop` — rescue around `disconnect!` so pool cleanup failure doesn't mask successful tenant drop

### General (address when touched)

- [ ] PoolReaper broad `rescue => e` in reap — consider narrowing to `ApartmentError` + `ActiveRecord::ActiveRecordError` in inner rescue loops
- [ ] `warn` calls in PoolReaper and PoolManager — migrate to `Rails.logger.error` when logging abstraction is built
- [ ] `define_callbacks :switch` is declared but never used — document as reserved or remove
- [ ] `Tenant.current` returns nil when unconfigured — consider raising `ConfigurationError` for fail-fast
- [ ] `Tenant.switch(nil)` silently sets tenant to nil — consider guarding with `ArgumentError`

### Test gaps (criticality 5-6, pick up opportunistically)

- [ ] `drop` partial failure when `drop_tenant` raises — document whether pool cleanup occurs
- [ ] LRU eviction default-tenant protection — direct test for LRU path (idle path tested)
- [ ] Fiber isolation for `Current` — validate the core v4 design claim with a fiber test
- [ ] `PoolManager#clear` disconnect verification — assert `disconnect!` called, not just count drops
- [ ] Concurrent `remove` + `get` race — document `Concurrent::Map` guarantees with a test
