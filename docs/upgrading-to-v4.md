# Upgrading to Apartment v4

## Requirements

- Ruby 3.3+
- Rails 7.2+
- PostgreSQL 14+
- MySQL 8.4+
- SQLite3

## What Changed and Why

v4 replaces the thread-local tenant switching model with pool-per-tenant architecture: each tenant gets a dedicated connection pool, eliminating cross-thread tenant leakage (a persistent problem in ActionCable, Sidekiq, and fiber-based servers). Tenant context is tracked via `ActiveSupport::CurrentAttributes`, making it fiber-safe by default. Configuration is immutable after boot (`Config#freeze!` runs after `Apartment.configure`). Global models use a declarative `pin_tenant` call on each class instead of a centralized config list.

## Breaking Changes

### Configuration

`config.tenant_names` has been removed. Use `config.tenants_provider` instead; it must be a callable (proc or lambda). The convenience method `Apartment.tenant_names` still works — it delegates to `config.tenants_provider.call`.

`config.tenant_strategy` is now required. Supported values: `:schema` (PostgreSQL schema-per-tenant) and `:database_name` (separate database per tenant). Additional strategies (`:shard`, `:database_config`) are reserved for future use and will raise `AdapterNotFound` if configured today.

`config.use_schemas` and `config.use_sql` have been removed. Use `tenant_strategy` for the isolation model and `schema_load_strategy` (`:schema_rb` or `:sql`) for schema loading on tenant creation.

Config is frozen after `Apartment.configure`. No runtime mutation; attempting to change config values after boot raises `FrozenError`.

Before/after:

```ruby
# v3
Apartment.configure do |config|
  config.excluded_models = %w[User Company]
  config.tenant_names = -> { Customer.pluck(:subdomain) }
  config.use_schemas = true
end

# v4
Apartment.configure do |config|
  config.tenant_strategy = :schema
  config.tenants_provider = -> { Customer.pluck(:subdomain) }
end
```

`default_tenant` auto-defaults to `'public'` for `:schema` strategy, matching v3 behavior. If you previously set it explicitly, you can remove the line. If your primary schema is something other than `public` (e.g., `shared`), set `config.default_tenant` to match. For `:database_name` strategy, you still need to set it.

### Tenant API

`Apartment::Tenant.switch` now requires a block. The manual switch/reset pattern (`switch!` then `reset` in `ensure`) is replaced by block-scoped switching that guarantees cleanup:

```ruby
# v3
Apartment::Tenant.switch!(tenant)
# ... work ...
ensure
  Apartment::Tenant.reset!

# v4
Apartment::Tenant.switch(tenant) do
  # ... work ...
end
```

`switch!` still exists for console/REPL use but is discouraged in application code.

`Apartment::Tenant.current` is unchanged between v3 and v4.

### Models

`config.excluded_models` is deprecated. It still works in v4 as a compatibility shim (resolved at initialization time into pinned model registrations) but will be removed in v5.

The replacement is declarative: include `Apartment::Model` and call `pin_tenant` on each global model.

```ruby
# v3
Apartment.configure do |config|
  config.excluded_models = %w[User Company]
end

# v4
class User < ApplicationRecord
  include Apartment::Model
  pin_tenant
end

class Company < ApplicationRecord
  include Apartment::Model
  pin_tenant
end
```

`process_excluded_models` is deprecated; use `process_pinned_models` instead. The deprecated method still works (it delegates internally) but emits a deprecation warning.

### Middleware

The v4 Railtie auto-inserts elevator middleware after `ActionDispatch::Callbacks` when `config.elevator` is set. Remove any manual `config.middleware.use` or `config.middleware.insert_before` lines from your application config. If you need custom middleware positioning, skip `config.elevator` and use the standard Rails `config.middleware.insert_before` API directly.

Configure via symbol:

```ruby
Apartment.configure do |config|
  config.elevator = :subdomain
  # config.elevator_options = { excluded_subdomains: %w[www] }
end
```

Available elevators: `:subdomain`, `:first_subdomain`, `:domain`, `:host`, `:host_hash`, `:header`, `:generic`.

### Connection Model

v4 uses pool-per-tenant instead of thread-local switching. Each tenant gets a dedicated `ActiveRecord::ConnectionAdapters::ConnectionPool` managed by `Apartment::PoolManager`.

Tenant context is stored in `Apartment::Current` (an `ActiveSupport::CurrentAttributes` subclass), which is fiber-safe by default. If your app uses fibers (e.g., Falcon server), ensure your Rails config sets:

```ruby
# config/application.rb
config.active_support.isolation_level = :fiber
```

The Railtie emits a boot-time warning if `isolation_level` is `:thread`.

### Pinned Model Connections

In v3, pinned (excluded) models always received their own connection pool via `establish_connection`. This meant they never participated in the same database transaction as tenant-scoped models.

v4 fixes this for strategies where the database engine supports cross-schema/database queries on a single connection:

| Strategy | Pinned model connection in v4 |
|---|---|
| PostgreSQL schema | Shares tenant connection (qualified table name) |
| MySQL / Trilogy | Shares tenant connection (qualified table name) |
| PostgreSQL database-per-tenant | Separate pool (unchanged from v3) |
| SQLite | Separate pool (unchanged from v3) |

For PG schema and MySQL/Trilogy, pinned models now use the tenant's connection pool with a fully qualified table name (e.g. `public.delayed_jobs`). This means pinned model writes participate in the same transaction as tenant DML.

**Action required if you relied on the old behavior:**

If your code assumes that pinned model writes survive a tenant transaction rollback (e.g., enqueuing a job and deliberately rolling back tenant data), set `force_separate_pinned_pool: true` in your Apartment config:

```ruby
Apartment.configure do |config|
  config.force_separate_pinned_pool = true
  # ...
end
```

`after_commit` callbacks still fire as before. The difference is that pinned model writes are now inside the tenant transaction, so an `ActiveRecord::Rollback` that aborts the transaction will also roll back pinned model writes. Apps using `after_commit` for job enqueueing are unaffected.

For PG database-per-tenant and SQLite, pinned model behavior is unchanged from v3. For MySQL multi-server setups where tenant databases are on different hosts, set `force_separate_pinned_pool: true`.

`pin_tenant` defers processing until the class body closes (when called after `Apartment.activate!`), so `self.table_name`, `table_name_prefix`, and `table_name_suffix` can appear anywhere in the class body. No ordering requirement between `pin_tenant` and table name configuration. For readability, declare table name configuration early in the class body. This works for standard `class MyModel < ApplicationRecord` definitions (source-parsed files loaded by Zeitwerk). For `MyModel = Class.new(ApplicationRecord) { ... }` style, the deferral cannot fire; call `Apartment.process_pinned_model(MyModel)` explicitly after assigning the constant.

Key config options for pool tuning:

| Option | Default | Description |
|--------|---------|-------------|
| `tenant_pool_size` | 5 | Connections per tenant pool |
| `pool_idle_timeout` | 300 | Seconds before idle pool eviction |
| `max_total_connections` | nil | Hard cap across all tenant pools |

## Migration Steps

### Step 1: Update Configuration

Replace your `config/initializers/apartment.rb`:

```ruby
# Before (v3)
Apartment.configure do |config|
  config.excluded_models = %w[User Company]
  config.tenant_names = -> { Customer.pluck(:subdomain) }
  config.use_schemas = true
end

# After (v4)
Apartment.configure do |config|
  config.tenant_strategy = :schema
  config.tenants_provider = -> { Customer.pluck(:subdomain) }

  # Optional: auto-load schema into new tenants
  # config.schema_load_strategy = :schema_rb

  # Optional: elevator (replaces manual middleware insertion)
  # config.elevator = :subdomain
end
```

For MySQL, use `config.tenant_strategy = :database_name`.

### Step 2: Update Models

For each model previously listed in `config.excluded_models`:

1. Add `include Apartment::Model` to the class
2. Add `pin_tenant` below the include
3. Remove the model name from the `config.excluded_models` array

```ruby
class User < ApplicationRecord
  include Apartment::Model
  pin_tenant

  # ... rest of model
end
```

Once all models are converted, delete the `config.excluded_models` line entirely.

For third-party gem models you cannot modify directly, `config.excluded_models` remains available as a transitional escape hatch.

### Step 3: Update Tenant Switching

Find and replace manual switch/reset patterns:

```ruby
# Before
Apartment::Tenant.switch!(tenant)
do_work
ensure
  Apartment::Tenant.reset!

# After
Apartment::Tenant.switch(tenant) do
  do_work
end
```

`Apartment::Tenant.current` is unchanged between v3 and v4; no migration needed for code that reads the current tenant.

`Apartment::Tenant.reset` (no bang) is available for cases where you need to return to the default tenant outside a block; `reset!` no longer exists in v4.

### Step 4: Update Middleware

Remove manual middleware insertion from `config/application.rb` or environment configs:

```ruby
# Delete these lines
config.middleware.use Apartment::Elevators::Subdomain
config.middleware.insert_before ActionDispatch::Session::CookieStore, Apartment::Elevators::Subdomain
```

Instead, configure the elevator in your Apartment initializer:

```ruby
Apartment.configure do |config|
  config.elevator = :subdomain
end
```

The Railtie handles middleware insertion and ordering automatically.

### Step 5: Update Background Jobs

Block-scoped switching in workers:

```ruby
# Sidekiq
class TenantJob
  include Sidekiq::Worker

  def perform(tenant, data)
    Apartment::Tenant.switch(tenant) do
      process(data)
    end
  end
end

# ActiveJob
class TenantJob < ApplicationJob
  def perform(tenant, data)
    Apartment::Tenant.switch(tenant) do
      process(data)
    end
  end
end
```

If you have a Sidekiq middleware that wraps all jobs in a tenant switch, update it to use the block form as well.

### Step 6: Update Tests

Reset tenant state in your test helper:

```ruby
RSpec.configure do |config|
  config.before(:each) do
    Apartment::Tenant.reset
  end
end
```

Use block-based switching in specs:

```ruby
it 'creates tenant-scoped records' do
  Apartment::Tenant.switch('test_tenant') do
    expect(Post.count).to eq(0)
  end
end
```

### Step 7: Verify

1. Run your full test suite
2. Check connection pool behavior under load in staging: `Apartment::Tenant.pool_stats` returns per-tenant pool metrics
3. Monitor for `FrozenError` exceptions, which indicate code attempting to mutate config after boot
4. Verify elevator middleware position with `Rails.application.middleware` (should appear after `ActionDispatch::Callbacks`)

## connects_to Compatibility

**Common case:** `ApplicationRecord` using `connects_to` with roles (`:writing`, `:reading`) on the same database works correctly. Apartment's `ConnectionHandling` patch routes tenant-aware lookups through the connection pool hierarchy.

**Separate database models:** If a model uses `connects_to` to point at an entirely separate database (e.g., a shared analytics DB), add `include Apartment::Model` and `pin_tenant` to ensure it bypasses tenant switching.

**Read replicas:** `connected_to(role: :reading)` works correctly with pinned models; the pinned model's connection targets the default tenant regardless of the active role.

## Troubleshooting

### "No connection defined for tenant"

The tenant name returned by your `tenants_provider` does not match what was created. Verify:

```ruby
Apartment.config.tenants_provider.call
# => ["tenant_a", "tenant_b"]
```

Ensure these names match exactly what `Apartment::Tenant.create` received (case-sensitive).

### Connection pool sizing

Each tenant gets `tenant_pool_size` connections (default: 5). For apps with many tenants, set `max_total_connections` to cap total database connections:

```ruby
Apartment.configure do |config|
  config.tenant_pool_size = 3
  config.max_total_connections = 100
end
```

Idle pools are evicted after `pool_idle_timeout` seconds (default: 300). The `PoolReaper` runs in the background and never evicts the default tenant's pool.

### Thread safety

Always use block-scoped `switch` in application code. `switch!` without a block does not guarantee cleanup on exceptions and can leak tenant context across fibers or threads.

```ruby
# Safe
Apartment::Tenant.switch(tenant) { do_work }

# Unsafe in production (acceptable in console)
Apartment::Tenant.switch!(tenant)
```

### Frozen config errors

If you see `FrozenError: can't modify frozen Apartment::Config`, you have code that mutates config after boot. Move all configuration into the `Apartment.configure` block in your initializer. Tests that need different config values must call `Apartment.configure` again (which creates a fresh config object).
