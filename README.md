# Apartment

[![Gem Version](https://badge.fury.io/rb/ros-apartment.svg)](https://badge.fury.io/rb/ros-apartment)
[![CI](https://github.com/rails-on-services/apartment/actions/workflows/ci.yml/badge.svg)](https://github.com/rails-on-services/apartment/actions/workflows/ci.yml)
[![codecov](https://codecov.io/gh/rails-on-services/apartment/graph/badge.svg?token=Q4I5QL78SA)](https://codecov.io/gh/rails-on-services/apartment)
[![Greptile: The War on Bugs](https://www.greptile.com/badge.svg)](https://www.greptile.com/?utm_source=oss_badge&utm_medium=readme&utm_campaign=greptile_for_open_source)

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

This gem is a maintained fork of the original [Apartment gem](https://github.com/influitive/apartment). Maintained by [CampusESP](https://www.campusesp.com) since 2024. Same `require 'apartment'`; v4 introduces a pool-per-tenant architecture that replaces the thread-local switching of v3. Tenant context is fiber-safe via `CurrentAttributes`, and connection pools are managed per tenant rather than swapping search paths on a shared connection. For *why* v4 chose this model over the alternatives (including fully-qualified table names), see [`docs/designs/v4-connection-model-rationale.md`](docs/designs/v4-connection-model-rationale.md). See the [upgrade guide](docs/upgrading-to-v4.md) for migration steps from v3.

## Installation

### Requirements

- Ruby 3.3+
- Rails 7.2+
- PostgreSQL 14+, MySQL 8.4+, or SQLite3

### Ruby version manager

`.ruby-version` is the single source of truth for the local Ruby version (the
same file `ruby/setup-ruby` reads in CI). Both [mise](https://mise.jdx.dev) and
[rbenv](https://github.com/rbenv/rbenv) honor it — use whichever you prefer:

```bash
# mise (recommended)
brew install mise                 # then add `eval "$(mise activate zsh)"` to ~/.zshrc
mise trust && mise install        # one-time trust per clone, then install the pinned Ruby

# rbenv (also works, unchanged)
rbenv install "$(cat .ruby-version)"
```

The committed `mise.toml` carries settings only (never a version): it tells mise
to honor `.ruby-version` without any per-developer global config. `mise trust`
is required once per clone; `bin/dev/setup-worktree` handles it for new worktrees.

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

`tenant_pool_size`: max connections per tenant pool. Default `nil` — each tenant pool inherits the app's base pool size (`DB_POOL_SIZE` / `pool:` in `database.yml`). **Set it to at least the peak number of threads/fibers in one process that can touch the _same_ tenant at once** (e.g. a Sidekiq role's concurrency for a same-tenant job fan-out); a smaller pool makes those threads block on connection checkout. It is a lazy ceiling — connections are created on demand and idle pools are reaped — so sizing for peak does not hold that many connections open at steady state.

`pool_idle_timeout`: seconds an idle tenant pool must exceed before it is eligible for reaping (default: 300).

`reaper_interval`: seconds between background reap passes. Default `nil` — derives from `pool_idle_timeout`. Set it lower to reap more often without shrinking the idle window.

`max_tenant_pools`: ceiling on the number of live tenant pools per process; `nil` for unlimited (default: `nil`). Enforced synchronously at pool-creation time (see `pool_overflow_policy`) and trimmed continuously by the background reaper.

`max_tenant_connections`: ceiling on total *tenant-pool* connections per process (default: `nil`); requires `tenant_pool_size`. The admission controller derives the pool budget as `floor(max_tenant_connections / tenant_pool_size)`. Per-process tenant-pool connections ≈ `effective_pool_budget × tenant_pool_size`, where `effective_pool_budget = min(max_tenant_pools, floor(max_tenant_connections / tenant_pool_size))`; the default pool and any separate pinned pool are additional. A tenant using multiple roles (e.g. `writing` + `reading`) holds one pool per role (`tenant:role` keys), counting once per role against the budget. For a hard external-pooler budget, pair this with `pool_overflow_policy: :raise` (the ceiling is soft under the default `:evict_idle`).

`max_total_connections`: **deprecated** (removed in v5) — it capped tenant-pool *count*, not connections. It now aliases `max_tenant_pools`; rename it. For a true connection ceiling, set `max_tenant_connections`.

`pool_overflow_policy`: behavior when a new pool would breach the pool budget (`max_tenant_pools` / `max_tenant_connections`) and every existing pool is pinned or in use (no idle pool to evict). `:evict_idle` (default) — allow the new pool, emit a `cap_unmet` notification (soft cap, prioritizes availability). `:raise` — raise `Apartment::PoolCapacityReached` (hard cap, sheds load). When an idle pool *is* available it is always evicted inline regardless of policy. See `docs/designs/pool-admission-control.md`.

`reap_in_test`: keep the background reaper running under `Rails.env.test?` (default `false` — the Railtie stops it in test, where fixture transactions make mid-example eviction a liability). Set `true` if a deployed process can run under test-env semantics and must keep reaping — that's cleaner than guarding `RAILS_ENV` at boot to avoid silently leaking connections. It applies to *every* `Rails.env.test?` process, including CI, so enable it only when a real deployment needs it.

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

`migration_role`: a Symbol naming the database role used for DDL (default: nil, uses the connection's default role). It covers migrations and tenant creation alike: the container, the `app_role` grants, and any `schema_load_strategy` import all run on it.

`app_role`: a String or callable returning the restricted role for application queries (default: nil).

Set both or neither. The grants Apartment installs at create time include an `ALTER DEFAULT PRIVILEGES` rule, and PostgreSQL scopes that rule to the role that executed it, so tenant creation and migrations have to share one role or the tables your migrations add land outside the rule. Apartment enforces that by running both on `migration_role`; configuring `app_role` alone leaves the rule bound to whichever role happened to create the tenant.

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

### Connection poolers in transaction mode (PgBouncer, RDS Proxy)

> [!WARNING]
> With the PostgreSQL `:schema` strategy, **PgBouncer in `transaction` pooling mode can
> silently serve one tenant another tenant's data.** No error is raised — queries return the
> wrong tenant's rows. It is safe only on **PostgreSQL 18+** with
> `track_extra_parameters = IntervalStyle,search_path`; on PostgreSQL 17 and older,
> transaction mode cannot be made safe and you must use `session` mode.

Tenant isolation under `:schema` rests on `search_path`, which is session-scoped state.
Transaction-mode pooling hands a different backend to each transaction, so a `search_path`
set by one client is not guaranteed to be the one in effect for the next query. This affects
v3 and v4 alike; v4 reduces the number of `SET search_path` statements to one per connection
but does not eliminate them, and one is enough.

**Which pooler to use:** PgBouncer on **PostgreSQL 18+** with
`track_extra_parameters = IntervalStyle,search_path` is the only setup that safely multiplexes
a schema-per-tenant app — and it needs no changes to Apartment or your application. **RDS Proxy
is safe but reduces no connections**: a Rails app pins on it *with or without Apartment* (three
unconditional `SET`s in `configure_connection`, plus the extended query protocol even at
`prepared_statements: false` — [rails/rails#40207](https://github.com/rails/rails/issues/40207)),
and AWS offers no session-pinning filters for PostgreSQL. Keep RDS Proxy if you use it for
failover or IAM; don't adopt it to cut connections.

Database-per-tenant (`:database_name`) is not affected.

**Read [Connection Poolers](docs/connection-poolers.md) before putting a pooler in front of a
schema-per-tenant app**, and verify your configuration rather than assuming it: the failure
is silent, so a working app proves nothing.

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

## Iterating across tenants

v4 keys a connection pool per `"tenant:role"`, so *switching* into a tenant creates a pool. Pick the lightest primitive for the work — the question is **does the block touch per-tenant-schema data?**

| Need | Use | v4 cost |
|---|---|---|
| Names only (enqueue a job, build a list) | `Apartment.tenant_names.each { ... }` | No switch, no pool created |
| Per-tenant-schema work (read/write tenant tables) | `Apartment::Tenant.each(release_connection: true) { ... }` | One pool per tenant; released between iterations |
| Global/pinned data only | Don't switch — read it in the default context | Under shared pinned connections (PG schema, MySQL default), a switch routes pinned/global models *through* the tenant pool |

Rules of thumb:

- **Enqueueing jobs?** Don't switch — pass the tenant as a job argument (`Job.perform_async(tenant: name)`) and let your worker middleware switch when the job runs. Switching only to enqueue spins up a pool for nothing.
- **Only need global/pinned data?** Don't switch. Under shared pinned connections a `switch` resolves pinned and excluded models through the *current tenant's* pool, so reading global data inside a switch still creates a tenant pool.
- **Large fan-out doing real per-tenant work?** Pass `release_connection: true` to `Tenant.each` — it releases connections after each tenant so the reaper can evict finished tenants' pools mid-run. It matters for blocks that hold a connection (raw `ActiveRecord::Base.connection`, an open transaction, a long operation); modern query methods (`create!`, `where`, …) check the connection back in themselves (Rails 7.2+), so a fan-out of only those needs no release. **It releases *every* connection leased to the current thread (`clear_active_connections!(:all)`), so don't use it inside an outer transaction or while holding a connection for non-tenant work.**

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

MIT — see [LICENSE](LICENSE). SPDX identifier: `MIT`.
