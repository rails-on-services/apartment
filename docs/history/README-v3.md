> **Note:** This documents Apartment v3.x. For v4, see [README.md](../../README.md).

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

This gem is a maintained fork of the original [Apartment gem](https://github.com/influitive/apartment). Maintained by [CampusESP](https://www.campusesp.com) since 2024. Drop-in replacement — same `require 'apartment'`, same API.

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

This creates `config/initializers/apartment.rb`. Configure it:

```ruby
Apartment.configure do |config|
  config.excluded_models = ['User', 'Company']  # shared across all tenants
  config.tenant_names = -> { Customer.pluck(:subdomain) }
end
```

## Usage

### Creating and Dropping Tenants

```ruby
Apartment::Tenant.create('acme')   # creates schema/database + runs migrations
Apartment::Tenant.drop('acme')     # permanently deletes tenant data
```

### Switching Tenants

Always use the block form — it guarantees cleanup even on exceptions:

```ruby
Apartment::Tenant.switch('acme') do
  # all ActiveRecord queries scoped to 'acme'
  User.create!(name: 'Alice')
end
# automatically restored to previous tenant
```

`switch!` exists for console/REPL use but is discouraged in application code.

### Switching per Request (Elevators)

Elevators are Rack middleware that detect the tenant from the request and switch automatically:

```ruby
# config/application.rb — pick one:
config.middleware.use Apartment::Elevators::Subdomain      # acme.example.com → 'acme'
config.middleware.use Apartment::Elevators::Domain          # acme.com → 'acme'
config.middleware.use Apartment::Elevators::Host            # full hostname matching
config.middleware.use Apartment::Elevators::HostHash, { 'acme.com' => 'acme_tenant' }
config.middleware.use Apartment::Elevators::FirstSubdomain  # first subdomain in chain
```

**Important:** Position the elevator middleware *before* authentication middleware (e.g., Warden/Devise) to ensure tenant context is established before auth runs:

```ruby
config.middleware.insert_before Warden::Manager, Apartment::Elevators::Subdomain
```

#### Custom Elevator

```ruby
# app/middleware/my_elevator.rb
class MyElevator < Apartment::Elevators::Generic
  def parse_tenant_name(request)
    # return tenant name based on request
    request.host.split('.').first
  end
end
```

### Excluded Models

Models that exist globally (not per-tenant):

```ruby
config.excluded_models = ['User', 'Company']
```

These models always query the default (public) schema. Use `has_many :through` for associations — `has_and_belongs_to_many` is not supported with excluded models.

### Excluded Subdomains

```ruby
Apartment::Elevators::Subdomain.excluded_subdomains = ['www', 'admin', 'public']
```

## Configuration

All options are set in `config/initializers/apartment.rb`:

```ruby
Apartment.configure do |config|
  # Required: how to discover tenant names (must be a callable)
  config.tenant_names = -> { Customer.pluck(:subdomain) }

  # Excluded models — shared across all tenants
  config.excluded_models = ['User', 'Company']

  # Default schema/database (default: 'public' for PostgreSQL)
  config.default_tenant = 'public'

  # Prepend Rails environment to tenant names (useful for dev/test)
  config.prepend_environment = !Rails.env.production?

  # Seed new tenants after creation
  config.seed_after_create = true

  # Enable ActiveRecord query logging with tenant context
  config.active_record_log = true
end
```

### PostgreSQL-Specific

```ruby
Apartment.configure do |config|
  # Schemas that remain in search_path for all tenants
  # (useful for shared extensions like hstore, uuid-ossp)
  config.persistent_schemas = ['shared_extensions']

  # Use raw SQL dumps instead of schema.rb for tenant creation
  # (needed for materialized views, custom types, etc.)
  config.use_sql = true
end
```

#### Setting Up Shared Extensions

PostgreSQL extensions (hstore, uuid-ossp, etc.) should be installed in a persistent schema:

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

### Migrations

Tenant migrations run automatically with `rake db:migrate`. Apartment iterates all tenants from `config.tenant_names`.

```ruby
# Disable automatic tenant migration if needed
Apartment.db_migrate_tenants = false  # in Rakefile, before load_tasks
```

#### Parallel Migrations

For applications with many schemas:

```ruby
config.parallel_migration_threads = 4    # 0 = sequential (default)
config.parallel_strategy = :auto         # :auto, :threads, or :processes
```

**Platform notes:** `:auto` uses threads on macOS (libpq fork issues) and processes on Linux. Parallel migrations disable PostgreSQL advisory locks — ensure your migrations are safe to run concurrently.

### Multi-Server Setup

Store tenants on different database servers:

```ruby
config.with_multi_server_setup = true
config.tenant_names = -> {
  Tenant.all.each_with_object({}) do |t, hash|
    hash[t.name] = { adapter: 'postgresql', host: t.db_host, database: 'postgres' }
  end
}
```

## Callbacks

Hook into tenant lifecycle events:

```ruby
require 'apartment/adapters/abstract_adapter'

Apartment::Adapters::AbstractAdapter.set_callback :create, :after do |adapter|
  # runs after a new tenant is created
end

Apartment::Adapters::AbstractAdapter.set_callback :switch, :before do |adapter|
  # runs before switching tenants
end
```

## Background Workers

For Sidekiq and ActiveJob tenant propagation:

- [apartment-sidekiq](https://github.com/rails-on-services/apartment-sidekiq)
- [apartment-activejob](https://github.com/rails-on-services/apartment-activejob)

## Rails Console

Apartment adds console helpers:

- `tenant_list` — list available tenants
- `st('tenant_name')` — switch to a tenant

For a tenant-aware prompt, add `require 'apartment/custom_console'` to `application.rb` (requires `pry-rails`).

## Troubleshooting

**Skip initial DB connection on boot:**

```bash
APARTMENT_DISABLE_INIT=true rails runner 'puts 1'
```

**Skip tenant presence check** (saves one query per switch on PostgreSQL):

```ruby
config.tenant_presence_check = false
```

## Contributing

1. Check [existing issues](https://github.com/rails-on-services/apartment/issues) and [discussions](https://github.com/rails-on-services/apartment/discussions)
2. Fork and create a feature branch
3. Write tests — we don't merge without them
4. Run `bundle exec rspec spec/unit/` and `bundle exec rubocop`
5. Use [Appraisal](https://github.com/thoughtbot/appraisal) to test across Rails versions: `bundle exec appraisal rspec spec/unit/`
6. Submit PR to the `development` branch

See [CONTRIBUTING.md](CONTRIBUTING.md) for full guidelines.

## License

[MIT License](http://www.opensource.org/licenses/MIT)
