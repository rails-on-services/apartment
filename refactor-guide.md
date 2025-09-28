# Apartment Gem Refactor — Goals, Scope, and Design

_(Rails 7.1/7.2/8 · Ruby 3.2–3.4)_

## 0 Problem Statement

The legacy Apartment model relied on global/process state and ad-hoc connection fiddling. It isn’t fiber-safe, drifts from modern Rails multi-DB APIs, and makes it too easy to leak one tenant’s context into another. We’re refactoring to a clear, Rails-native, **thread/fiber-safe** design that remains fast for hundreds of tenants and easy to roll out.

---

## 1 Primary Objectives

1. **Isolated connection pools per tenant**
   Each tenant gets its own dedicated connection pool via `TenantConnectionDescriptor`. No connection switching - each pool is permanently bound to its tenant.
   Ref: [Rails API: ConnectionHandler](https://api.rubyonrails.org/classes/ActiveRecord/ConnectionAdapters/ConnectionHandler.html)

2. **Thread & fiber safety**
   Hold the **current tenant** (and only that) in [`ActiveSupport::CurrentAttributes`](https://api.rubyonrails.org/classes/ActiveSupport/CurrentAttributes.html) (fiber/thread isolated; resets per request).

3. **Immutable tenant-per-connection design**
   Once a connection is established for a tenant, it remains bound to that tenant. No runtime connection switching or search_path manipulation per query.

4. **Deterministic switching with automatic cleanup**
   All switching goes through `Apartment::Tenant.switch(tenant) { … }` which guarantees setup+reset even on exceptions.

5. **PostgreSQL schema isolation**
   Each tenant connection pool is configured with its dedicated schema via `SET search_path`. Schema is set once during connection establishment.
   Ref: [Postgres docs: Schemas & search_path](https://www.postgresql.org/docs/current/ddl-schemas.html#DDL-SCHEMAS-PATH)

6. **Multiple tenant strategies**
   - `:schema` - PostgreSQL schema-per-tenant (default)
   - `:database_per_tenant` - Separate databases
   - `:shard` - Rails native sharding (future)
   - `:database_config` - Custom database configurations

7. **Static, thread-safe tenants list**
   `tenants_provider` is a **callable** returning either strings (shared config) or per-tenant hashes (custom DSN). Cache at boot; expose `reload_tenants!` for hot reloads.

8. **Connection pool management**
   Custom `ConnectionHandler` and `PoolManager` classes extend Rails' native connection handling to support tenant-specific pools.

9. **Core public API (implemented)**
   - `Apartment::Tenant.current` - Get current tenant
   - `Apartment::Tenant.switch(tenant) { ... }` - Block-scoped tenant switching
   - `Apartment::Tenant.switch!(tenant)` - Manual tenant switching
   - `Apartment::Tenant.reset` - Reset to default tenant

10. **Rails 7.1/7.2/8 compatibility**
    Only rely on documented Rails APIs (CurrentAttributes, connected_to, connects_to).

---

## 2 Non-Goals (for this iteration)

- Row-level multi-tenancy (RLS) or authorization concerns.
- Auto-sharding / read-write splitting policy engines.
- Full tenant lifecycle UIs (keep simple programmatic hooks).
- Migrations DSL rewrite (we’ll provide helpers to iterate tenants).

---

## 3 Public Configuration & API

### 3.1 Initializer

```ruby
# config/initializers/apartment.rb
Apartment.configure do |config|
  config.tenants_provider = -> { TenantRegistry.fetch_all }
  config.default_tenant = "public"
  config.tenant_strategy = :schema
  # Optional: Configure PostgreSQL-specific settings
  config.configure_postgres do |pg|
    pg.excluded_schemas = %w[shared_extensions]
  end
end
```

### 3.2 Runtime API

```ruby
# Core tenant operations
Apartment::Tenant.current                    # => "public"
Apartment::Tenant.switch("acme") do
  User.all  # Queries acme.users table
end
Apartment::Tenant.switch!("acme")            # Manual switch
Apartment::Tenant.reset                      # Back to default

# Configuration-driven tenant list
config.tenants_provider.call                # => ["tenant1", "tenant2"]
```

## 4 Connection Pool Architecture

### 4.1 TenantConnectionDescriptor

The core innovation is `TenantConnectionDescriptor` which wraps ActiveRecord model classes with tenant context:

```ruby
# Creates tenant-specific connection identifier
descriptor = TenantConnectionDescriptor.new(ActiveRecord::Base, "tenant1")
descriptor.name  # => "ActiveRecord::Base[tenant1]"
```

### 4.2 Connection Pool Isolation

```ruby
# Each tenant gets its own connection pool
connection_name_to_pool_manager["ActiveRecord::Base[tenant1]"] = PoolManager.new
connection_name_to_pool_manager["ActiveRecord::Base[tenant2]"] = PoolManager.new

# Pools are completely isolated - no sharing between tenants
```

### 4.3 Tenant Strategy Implementation

**Schema Strategy** (`:schema`):
- Each connection pool configured with `SET search_path TO "tenant_name"`
- Schema set once during connection establishment
- Optimal for PostgreSQL multi-tenancy

**Database Strategy** (`:database_per_tenant`):
- Each pool points to different database via custom db_config
- Complete database-level isolation
- Suitable for high-isolation requirements

## 5 Current Tenant Tracking

```ruby
class Apartment::Current < ActiveSupport::CurrentAttributes
  attribute :tenant
end
```

-	Fiber/thread-isolated.
-	Reset automatically at request boundaries.

Ref: Rails API: CurrentAttributes

## 6 Excluded (Global) Models

-	Models in excluded_models always use the global connection.
-	Apps can also pin with connects_to.

Ref: Rails Guides: Multiple Databases

## 7 Rails Integration Points

-	Rack middleware / Controller around_action to wrap requests.
-	Active Job / Sidekiq middleware to switch tenant before job perform.
-	Console/Rake helpers for tenant-specific work and migrations.

## 8 Error Handling & Guards

-	Validate tenant membership before switching.
-	Always clear Apartment::Current.tenant on block exit.
-	Postgres: keep tenant-scoped work inside transactions.
-	DB-per-tenant: always use connected_to blocks.

## 9 Performance Notes

**Schema Strategy**:
- Multiple connection pools but shared database
- Efficient for hundreds of tenants
- Memory usage scales with active tenant count

**Database Strategy**:
- Each tenant gets dedicated database connection pool
- Higher resource usage but complete isolation
- Suitable for smaller tenant counts with high isolation needs

## 10 Migration & Rollout

**Requirements**:
- Rails ≥ 7.1 and Ruby ≥ 3.2
- PostgreSQL, MySQL, or SQLite3 database adapter

**Migration Steps**:
1. Replace `tenant_names` config with `tenants_provider` callable
2. Set `tenant_strategy` (`:schema`, `:database_per_tenant`, etc.)
3. Update middleware to use block-scoped `switch` method
4. Verify excluded models work with new connection handling

## 11 Extension Path: Sharding

```ruby
Apartment.with_tenant("acme", shard: :shard_2) { ... }
```

-	Delegates to Rails’ connected_to(role:, shard:).

## 12 Minimal Code Sketch

```ruby
module Apartment
  class << self
    def with_tenant(name, &blk)
      previous = Apartment::Current.tenant
      if config.adapter == :postgres_schemas
        pg_with_schema(name, &blk)
      else
        with_database_for(name, &blk)
      end
    ensure
      Apartment::Current.tenant = previous
    end

    def pg_with_schema(name)
      Apartment::Current.tenant = name
      ActiveRecord::Base.connection.transaction(joinable: false, requires_new: true) do
        ActiveRecord::Base.connection.execute(%Q[SET LOCAL search_path = "#{name}", public])
        yield
      end
    end
  end
end
```

## 13 Acceptance Criteria

-	✅ All switching goes through with_tenant.
-	✅ No leakage across 50+ parallel requests/jobs.
-	✅ Postgres search_path always reverts after block exit.
-	✅ DB-per-tenant restores connections and bounds pools.
-	✅ Rails 7.1/7.2/8 + Ruby 3.2/3.3/3.4 test matrix green.
-	✅ Migration guide + sample initializer/middleware provided.

## References

-	Rails Guides: Multiple Databases
-	Rails API: ActiveRecord::ConnectionHandling#connected_to
-	Rails API: ActiveSupport::CurrentAttributes
-	Postgres docs: SET / SET LOCAL
-	Postgres docs: Schemas & search_path
