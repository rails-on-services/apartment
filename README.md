# Apartment

[![Gem Version](https://badge.fury.io/rb/ros-apartment.svg)](https://badge.fury.io/rb/ros-apartment)
[![CI](https://github.com/rails-on-services/apartment/actions/workflows/ci.yml/badge.svg)](https://github.com/rails-on-services/apartment/actions/workflows/ci.yml)
[![codecov](https://codecov.io/gh/rails-on-services/apartment/graph/badge.svg?token=Q4I5QL78SA)](https://codecov.io/gh/rails-on-services/apartment)

*Database-level multitenancy for Rails and ActiveRecord*

Apartment isolates tenant data at the **database level** — using PostgreSQL schemas or separate databases — so that tenant data separation is enforced by the database engine, not application code.

```ruby
Apartment::Tenant.switch('acme') do
  User.all  # only returns users in the 'acme' schema/database
end
```

## When to Use Apartment

Apartment uses **schema-per-tenant** (PostgreSQL) or **database-per-tenant** (MySQL/SQLite) isolation. This is one of several approaches to multitenancy in Rails. Choose the right one for your situation:

| Approach | Isolation | Best for | Gem |
|----------|-----------|----------|-----|
| **Row-level** (shared tables, `WHERE tenant_id = ?`) | Application-enforced | Many tenants, greenfield apps, cross-tenant reporting | [`acts_as_tenant`](https://github.com/ErwinM/acts_as_tenant) |
| **Schema-level** (PostgreSQL schemas) | Database-enforced | Fewer high-value tenants, regulatory requirements, retrofitting existing apps | `ros-apartment` |
| **Database-level** (separate databases) | Full isolation | Strictest isolation, per-tenant performance tuning | `ros-apartment` |

**Use Apartment when** you need hard data isolation between tenants — where a missed `WHERE` clause can't accidentally leak data across tenants. This is common in regulated industries, B2B SaaS with contractual isolation requirements, or when retrofitting an existing single-tenant app.

**Consider row-level tenancy instead** if you have many tenants (hundreds+), need cross-tenant queries, or are starting a greenfield project. Row-level is simpler, uses fewer database resources, and scales more linearly. See the [Arkency comparison](https://blog.arkency.com/comparison-of-approaches-to-multitenancy-in-rails-apps/) for a thorough analysis.

## About ros-apartment

This gem is a maintained fork of the original [Apartment gem](https://github.com/influitive/apartment). Maintained by [CampusESP](https://www.campusesp.com) since 2024. Same `require 'apartment'`; v4 introduces a pool-per-tenant architecture that replaces the thread-local switching of v3. Tenant context is fiber-safe via `CurrentAttributes`, and connection pools are managed per tenant rather than swapping search paths on a shared connection. See the [upgrade guide](docs/upgrading-to-v4.md) for migration steps from v3.

## Installation

### Requirements

- Ruby 3.3+
- Rails 7.2+
- PostgreSQL 14+, MySQL 8.4+, or SQLite3

### Setup

```ruby
# Gemfile
gem 'ros-apartment', require: 'apartment'
```

```bash
bundle install
bundle exec rails generate apartment:install
```

## Quick Start

The generated initializer at `config/initializers/apartment.rb` configures Apartment:

```ruby
Apartment.configure do |config|
  config.tenant_strategy = :schema          # :schema (PostgreSQL) or :database_name (MySQL/SQLite)
  config.tenants_provider = -> { Customer.pluck(:subdomain) }
  config.default_tenant = 'public'          # auto-defaults for :schema; required for :database_name
end
```

Tenant context is block-scoped. Always use `Apartment::Tenant.switch` with a block in application code; it guarantees cleanup on exceptions.

```ruby
Apartment::Tenant.create('acme')

Apartment::Tenant.switch('acme') do
  User.create!(name: 'Alice')  # in the 'acme' schema
end

Apartment::Tenant.drop('acme')
```

`switch!` exists for console/REPL use but is discouraged in application code.

Global models that live outside tenant schemas use `pin_tenant`:

```ruby
class Company < ApplicationRecord
  include Apartment::Model
  pin_tenant  # always queries the default (public) schema
end
```

## Configuration Reference

All options are set in `config/initializers/apartment.rb` inside an `Apartment.configure` block.

### Required Options

`tenant_strategy`: the isolation method. `:schema` for PostgreSQL schema-per-tenant, `:database_name` for MySQL/SQLite database-per-tenant.

`tenants_provider`: a callable that returns tenant names. Called at migration time and by rake tasks. Example: `-> { Customer.pluck(:subdomain) }`.

### Pool Settings

`tenant_pool_size`: max connections per tenant pool. Default `nil` — each tenant pool inherits the app's base pool size (`DB_POOL_SIZE` / `pool:` in `database.yml`). Set it to size tenant pools independently of the app pool (e.g. to bound total connections across many schema-per-tenant pools).

`pool_idle_timeout`: seconds an idle tenant pool must exceed before it is eligible for reaping (default: 300).

`reaper_interval`: seconds between background reap passes. Default `nil` — derives from `pool_idle_timeout`. Set it lower to reap more often without shrinking the idle window.

`max_total_connections`: ceiling on the number of live tenant pools; `nil` for unlimited (default: `nil`). Enforced synchronously at pool-creation time (see `pool_overflow_policy`) and trimmed continuously by the background reaper. Total backend connections ≈ `max_total_connections × tenant_pool_size`.

`pool_overflow_policy`: behavior when a new pool would breach `max_total_connections` and every existing pool is pinned or in use (no idle pool to evict). `:evict_idle` (default) — allow the new pool, emit a `cap_unmet` notification (soft cap, prioritizes availability). `:raise` — raise `Apartment::PoolCapacityReached` (hard cap, sheds load). When an idle pool *is* available it is always evicted inline regardless of policy. See `docs/designs/pool-admission-control.md`.

### Observability

Apartment emits `ActiveSupport::Notifications` for the pool lifecycle and ships
`Apartment::PoolObserver`, a sink-agnostic subscriber + sampler. See
[docs/observability.md](docs/observability.md).

### Elevator (Request Tenant Detection)

```ruby
config.elevator = :subdomain
config.elevator_options = {}
```

The Railtie auto-inserts elevator middleware after `ActionDispatch::Callbacks` (just before cookies/sessions in full mode; works in API mode too).

See the [Elevators](#elevators) section for available options.

### Migrations

`parallel_migration_threads`: number of threads for parallel tenant migration; 0 for sequential (default: 0).

`schema_load_strategy`: how to initialize new tenant schemas on create. `nil` (no schema loading), `:schema_rb`, or `:sql` (default: nil).

`seed_after_create`: run seeds after tenant creation (default: false).

`seed_data_file`: path to a custom seeds file; uses `db/seeds.rb` when nil (default: nil).

`schema_file`: path to a custom schema file for tenant creation (default: nil).

`check_pending_migrations`: raise `PendingMigrationError` in local environments when a tenant has unapplied migrations (default: true).

### Advanced

`schema_cache_per_tenant`: load per-tenant schema cache files when establishing tenant pools (default: false).

`active_record_log`: tag Rails log output with the current tenant using `ActiveSupport::TaggedLogging`. Log lines inside a `switch` block are tagged with `tenant=name`; nested switches stack tags (`[tenant=acme] [tenant=widgets]`). Requires `Rails.logger` to respond to `tagged` (default: false).

`sql_query_tags`: add a `tenant` tag to `ActiveRecord::QueryLogs` so SQL queries include a `/* tenant='name' */` comment. Visible in slow query logs, `pg_stat_activity`, and database monitoring tools (default: false).

`shard_key_prefix`: prefix for ActiveRecord shard keys used in tenant pool registration (default: `'apartment'`). Must match `/[a-z_][a-z0-9_]*/`.

### Tenant Naming

`environmentify_strategy`: how to namespace tenant names per Rails environment. `nil` (no prefix), `:prepend`, `:append`, or a callable (default: nil).

### RBAC

`migration_role`: a Symbol naming the database role used for migrations (default: nil, uses the connection's default role).

`app_role`: a String or callable returning the restricted role for application queries (default: nil).

### PostgreSQL

```ruby
Apartment.configure do |config|
  config.configure_postgres do |pg|
    pg.persistent_schemas = ['shared_extensions']
  end
end
```

PostgreSQL extensions (hstore, uuid-ossp, etc.) should be installed in a persistent schema so they're accessible from all tenant schemas:

```ruby
# lib/tasks/db_enhancements.rake
namespace :db do
  task extensions: :environment do
    ActiveRecord::Base.connection.execute('CREATE SCHEMA IF NOT EXISTS shared_extensions;')
    ActiveRecord::Base.connection.execute('CREATE EXTENSION IF NOT EXISTS HSTORE SCHEMA shared_extensions;')
    ActiveRecord::Base.connection.execute('CREATE EXTENSION IF NOT EXISTS "uuid-ossp" SCHEMA shared_extensions;')
  end
end

Rake::Task['db:create'].enhance { Rake::Task['db:extensions'].invoke }
Rake::Task['db:test:purge'].enhance { Rake::Task['db:extensions'].invoke }
```

Ensure your `database.yml` includes the persistent schema:

```yaml
schema_search_path: "public,shared_extensions"
```

Additional PostgreSQL options (set inside the `configure_postgres` block):

`include_schemas_in_dump`: non-public schemas to include in schema dumps, e.g., `%w[ext shared]` (default: []).

### MySQL

```ruby
Apartment.configure do |config|
  config.configure_mysql do |my|
    # MySQL-specific options
  end
end
```

## Elevators

Elevators are Rack middleware that detect the tenant from the incoming request and call `Apartment::Tenant.switch` for the duration of that request.

Available elevators:

- Subdomain: `acme.example.com` -> `'acme'`
- Domain: `acme.com` -> `'acme'`
- Host: full hostname matching
- HostHash: `{ 'acme.com' => 'acme_tenant' }`
- FirstSubdomain: first subdomain in a multi-level chain
- Header: tenant name from an HTTP header (new in v4)

Configuration via `config.elevator`:

```ruby
Apartment.configure do |config|
  config.elevator = :subdomain
end
```

The Railtie inserts the elevator after `ActionDispatch::Callbacks` automatically. In the full middleware stack this places it just before cookies, sessions, and authentication. In API mode (where cookies/sessions are absent), `Callbacks` is still present so the elevator works without changes.

If you need different positioning, skip `config.elevator` and insert manually:

```ruby
# config/application.rb
config.middleware.insert_before 'Warden::Manager', Apartment::Elevators::Subdomain
```

### Custom Elevator

```ruby
class MyElevator < Apartment::Elevators::Generic
  def parse_tenant_name(request)
    request.host.split('.').first
  end
end
```

Then pass the class directly:

```ruby
config.elevator = MyElevator
```

## Pinned Models (Global Tables)

Models that belong to all tenants (users, companies, plans) are pinned to the default schema:

```ruby
class User < ApplicationRecord
  include Apartment::Model
  pin_tenant
end
```

Why `pin_tenant`:

- Declarative: the model declares its own tenancy, not a distant config list
- Zeitwerk-safe: no string-to-class resolution at boot time
- Composable: works with `connected_to(role: :reading)` for read replicas

Use `has_many :through` for associations between pinned and tenant models. `has_and_belongs_to_many` is not supported across schemas.

Pinned models work correctly inside `connected_to(role: :reading)` blocks. The pin bypasses Apartment's tenant routing; Rails' own role routing takes over.

For the edge case of models using `connects_to` with a separate database, see [Known Limitations](#known-limitations).

## Callbacks

Hook into tenant lifecycle events:

```ruby
Apartment::Adapters::AbstractAdapter.set_callback :create, :after do |adapter|
  # runs after a new tenant is created
end

Apartment::Adapters::AbstractAdapter.set_callback :switch, :before do |adapter|
  # runs before switching tenants
end
```

## Migrations

Rake tasks:

- `apartment:create`: create all tenants from `tenants_provider`
- `apartment:drop`: drop all tenants
- `apartment:migrate`: run pending migrations on all tenants
- `apartment:seed`: seed all tenants
- `apartment:rollback`: rollback last migration on all tenants

The Railtie hooks the primary `db:migrate` task (when defined) so that tenant migrations run after the primary database migrates.

### Parallel Migrations

For applications with many schemas:

```ruby
config.parallel_migration_threads = 4    # 0 = sequential (default)
```

Platform notes: parallel migrations use threads. On macOS, libpq has known fork-safety issues, so threads are preferred over processes. Parallel migrations disable PostgreSQL advisory locks; ensure your migrations are safe to run concurrently.

## Known Limitations

### `connects_to` with Separate Databases

If a model (or its abstract base class) uses `connects_to` to point at a completely different database (not just different roles on the same DB), Apartment's `connection_pool` patch will attempt to create a tenant pool for it.

Workaround: add `include Apartment::Model` and `pin_tenant` on the abstract class or model that declares `connects_to` to a separate database.

The common pattern of `ApplicationRecord` using `connects_to` with multiple roles (writing/reading) on the same database works correctly; Apartment keys pools by `tenant:role` and respects Rails' role routing.

## ActionController::Live Streaming

Apartment v4 handles tenant propagation across `ActionController::Live`'s spawned streaming thread automatically, under both `:thread` and `:fiber` isolation. Including `ActionController::Live` in your controller is sufficient — no additional configuration:

```ruby
class StreamingController < ApplicationController
  include ActionController::Live

  def show
    response.headers['Content-Type'] = 'text/event-stream'
    # Apartment::Tenant.current returns the request's tenant here,
    # even though we're now executing on the OS thread Rails spawned
    # for streaming.
    response.stream.write("data: #{{ tenant: Apartment::Tenant.current }.to_json}\n\n")
  ensure
    response.stream.close
  end
end
```

How it works: Apartment prepends `ActionController::Live#process` with a patch that backports [rails/rails#56902](https://github.com/rails/rails/pull/56902) to released Rails versions — it points `Thread.current.active_support_execution_state` at the request fiber's hash for the duration of the request, so Rails' own `share_with` carries all `CurrentAttributes` (apartment's tenant plus any app-defined ones) into the spawned streaming thread. User-spawned threads or fibers *inside* a Live action (`Thread.new`, `Async { }`, raw `Fiber.new`) escape the patch and need explicit `Apartment::Tenant.switch` wrapping. See the [upgrading guide](docs/upgrading-to-v4.md) and [`docs/designs/rails-boundary-tenancy.md`](docs/designs/rails-boundary-tenancy.md).

## Background Workers

Use block-scoped switching in jobs:

```ruby
class TenantJob < ApplicationJob
  def perform(tenant, data)
    Apartment::Tenant.switch(tenant) do
      # process job
    end
  end
end
```

For automatic tenant propagation:

- [apartment-sidekiq](https://github.com/rails-on-services/apartment-sidekiq)
- [apartment-activejob](https://github.com/rails-on-services/apartment-activejob)

A job that forgets to switch runs in the default tenant — for `Rails.cache` and
other `Tenant.current`-derived resources that silently contaminate another
tenant's keyspace. Guard routed work with `Apartment::Tenant.require_tenant!`
(raises unless a real, non-default tenant is active) and pinned/global work with
`require_default_tenant!`. See [Tenant-Aware Caching](docs/caching.md) for the
routed-vs-pinned model and the two-store recipe.

## Convenience Methods

`Apartment.tenant_names` returns the current tenant list (delegates to `config.tenants_provider.call`). Preserves the v3 API so existing call sites work without changes.

`Apartment.excluded_models` returns the excluded models list (delegates to `config.excluded_models`). Deprecated in v4; use `Apartment::Model` + `pin_tenant` instead.

## Troubleshooting

If tenant switching raises unexpected errors, verify that `tenants_provider` returns valid tenant names and that the tenant exists in the database.

## Upgrading from v3

See the [upgrade guide](docs/upgrading-to-v4.md) for a complete list of breaking changes and migration steps.

## RuboCop cops

Apartment ships two optional RuboCop cops that enforce the block-form
tenant-switching discipline. Enable them in your application's `.rubocop.yml`:

```yaml
require: rubocop/apartment
inherit_gem:
  ros-apartment: config/default.yml
```

- **`Apartment/NoDirectCurrentWrite`** (error) — bans assigning
  `Apartment::Current.tenant` / `.previous_tenant` directly. Change tenant context
  with `Apartment::Tenant.switch(tenant) { ... }` (or `with_default_tenant` for
  global work), which guarantees a restore via `ensure`.
- **`Apartment/PreferBlockSwitch`** (warning) — nudges `Apartment::Tenant.switch!`
  toward the block form. `reset` is not flagged.

Both match the qualified `Apartment::` receiver only. Scope them to your
application code with the standard `Exclude:` keys if needed. See
[`docs/designs/rubocop-cops.md`](docs/designs/rubocop-cops.md) for the rationale.

## Contributing

1. Check [existing issues](https://github.com/rails-on-services/apartment/issues) and [discussions](https://github.com/rails-on-services/apartment/discussions)
2. Fork and create a feature branch
3. Write tests: we don't merge without them
4. Run `bundle exec rspec spec/unit/` and `bundle exec rubocop`
5. Use [Appraisal](https://github.com/thoughtbot/appraisal) to test across Rails versions: `bundle exec appraisal rspec spec/unit/`
6. Submit PR to the `main` branch

## License

[MIT License](http://www.opensource.org/licenses/MIT)
