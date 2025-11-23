# CLAUDE.md - Apartment v3 Comprehensive Guide

**Version**: 3.x (Current Development Branch)
**Maintained by**: CampusESP
**Gem Name**: `ros-apartment` (fork of original `apartment` gem)

## Project Overview

Apartment is a **multi-tenancy gem** for Rails and ActiveRecord that enables data isolation across multiple tenants within a single Rails application. It supports two primary isolation strategies:

1. **Schema-based** (PostgreSQL) - Multiple schemas within a single database
2. **Database-based** (MySQL, SQLite) - Separate databases per tenant

### Key Characteristics

- **Thread-local tenant switching** via `Thread.current[:apartment_adapter]`
- **Middleware-based** automatic tenant routing ("Elevators")
- **Adapter pattern** for database-specific implementations
- **Excluded models** that exist outside tenant contexts
- **Callbacks** for tenant lifecycle events
- **Rails integration** via Railtie and ActiveRecord extensions

---

## Architecture Overview

### Core Components

```
lib/apartment/
├── apartment.rb              # Main module with configuration DSL
├── tenant.rb                 # Public API for tenant operations
├── adapters/                 # Database-specific tenant isolation
│   ├── abstract_adapter.rb  # Base adapter with shared logic
│   ├── postgresql_adapter.rb # PostgreSQL schema-based isolation
│   ├── mysql2_adapter.rb    # MySQL database-based isolation
│   ├── sqlite3_adapter.rb   # SQLite file-based isolation
│   └── [other adapters]
├── elevators/                # Middleware for automatic tenant switching
│   ├── generic.rb           # Base elevator with customizable logic
│   ├── subdomain.rb         # Switch based on subdomain
│   ├── domain.rb            # Switch based on domain
│   ├── host.rb              # Switch based on full hostname
│   └── [other elevators]
├── active_record/           # ActiveRecord patches and extensions
│   ├── connection_handling.rb
│   ├── schema_migration.rb
│   └── postgresql_adapter.rb
└── railtie.rb               # Rails initialization hooks
```

### Design Patterns

**Adapter Pattern**
- Each database type has a specific adapter (PostgreSQL, MySQL, SQLite, JDBC variants)
- All adapters inherit from `AbstractAdapter` and implement core methods
- Adapter selection is automatic based on `database.yml` configuration

**Delegation Pattern**
- `Apartment::Tenant` delegates to the appropriate adapter
- `Apartment` module delegates connection methods to `connection_class`

**Middleware Pattern**
- "Elevators" are Rack middleware that intercept requests
- Each elevator extracts tenant name from request (subdomain, domain, etc.)
- Tenant context is automatically established before request processing

**Callback Pattern**
- `:create` and `:switch` callbacks via `ActiveSupport::Callbacks`
- Allows custom logic before/after tenant operations
- Useful for logging, notifications, analytics

---

## Configuration

### Basic Configuration (config/initializers/apartment.rb)

```ruby
Apartment.configure do |config|
  # Tenant list - can be array, hash, or callable
  config.tenant_names = lambda { Company.pluck(:subdomain) }

  # Excluded models (exist outside tenant schemas)
  config.excluded_models = %w[Company User]

  # PostgreSQL: schemas to keep in search_path
  config.persistent_schemas = %w[shared_extensions]

  # Default tenant (usually 'public' for PostgreSQL)
  config.default_tenant = 'public'

  # Seed tenants after creation
  config.seed_after_create = true

  # Prepend/append environment to tenant names
  config.prepend_environment = !Rails.env.production?
  # config.append_environment = !Rails.env.production?

  # Database migration settings
  config.db_migrate_tenants = true
  config.db_migrate_tenant_missing_strategy = :rescue_exception
  # Options: :rescue_exception, :raise_exception, :create_tenant

  # Parallel migrations (0 = sequential)
  config.parallel_migration_threads = 0

  # ActiveRecord logging
  config.active_record_log = false

  # PostgreSQL: tables to exclude from schema cloning
  config.pg_excluded_names = /^(backup_|temp_)/

  # Custom connection class (default: ActiveRecord::Base)
  # config.connection_class = CustomConnectionClass
end
```

### Configuration Options Explained

**`tenant_names`**
- **Type**: Array, Hash, or callable (proc/lambda)
- **Purpose**: Define available tenants
- **Array**: Static list of tenant names
- **Hash**: Maps tenant names to database configurations
- **Callable**: Dynamic tenant discovery (recommended for database-backed tenant lists)

**`excluded_models`**
- **Type**: Array of strings
- **Purpose**: Models that exist outside tenant contexts
- **Common uses**: User authentication, tenant registry, shared lookup tables
- **Behavior**: These models establish their own connections outside tenant switching

**`persistent_schemas` (PostgreSQL only)**
- **Type**: Array of strings
- **Purpose**: Schemas that remain in `search_path` alongside tenant schema
- **Common uses**: Extensions (e.g., `hstore`, `uuid-ossp`), shared utilities
- **Example**: `['public', 'shared_extensions']`

**`prepend_environment` / `append_environment`**
- **Type**: Boolean
- **Purpose**: Add Rails environment to tenant names
- **Development**: Creates `development_acme` instead of `acme`
- **Benefits**: Prevents collisions across environments

**`db_migrate_tenant_missing_strategy`**
- **`:rescue_exception`**: Log error, continue with other tenants
- **`:raise_exception`**: Stop migration on missing tenant
- **`:create_tenant`**: Automatically create missing tenant

**`parallel_migration_threads`**
- **Type**: Integer
- **Purpose**: Run tenant migrations concurrently
- **0**: Sequential (default, safest)
- **N > 0**: Use N threads for parallel execution

---

## Tenant Operations

### Creating Tenants

```ruby
# Basic creation (runs all migrations)
Apartment::Tenant.create('acme_corp')

# With custom logic after creation
Apartment::Tenant.create('acme_corp') do
  # Seed custom data
  AdminUser.create!(email: 'admin@acme.com')

  # Configure tenant-specific settings
  Setting.create!(key: 'logo_url', value: 'https://...')
end
```

**What happens during creation:**
1. Adapter creates schema/database based on strategy
2. All migrations run against new tenant
3. Schema structure matches current `db/schema.rb`
4. Seeds run if `seed_after_create = true`
5. Block executed within tenant context (if provided)
6. `:create` callbacks fired before/after

### Switching Tenants

```ruby
# Block-based (recommended - automatic cleanup)
Apartment::Tenant.switch('acme_corp') do
  # All ActiveRecord queries use acme_corp tenant
  users = User.all
  orders = Order.where(created_at: Date.today)
end
# Automatically switched back to previous tenant

# Manual switching (not recommended - no automatic cleanup)
previous = Apartment::Tenant.current
Apartment::Tenant.switch!('acme_corp')
begin
  # Do work
ensure
  Apartment::Tenant.switch!(previous)
end

# Reset to default tenant
Apartment::Tenant.reset
# Now in 'public' schema (or configured default_tenant)

# PostgreSQL only: Multiple schema search
Apartment::Tenant.switch(['tenant_a', 'tenant_b']) do
  # Searches tenant_a first, then tenant_b
  record = Record.find(123)
end
```

**Thread Safety**
Each thread maintains its own tenant context via `Thread.current[:apartment_adapter]`. This ensures:
- No cross-thread contamination
- Safe for concurrent requests in multi-threaded servers (Puma, Falcon)
- Automatic isolation in background jobs (Sidekiq, GoodJob)

### Dropping Tenants

```ruby
# Permanently delete tenant schema/database
Apartment::Tenant.drop('acme_corp')
```

**⚠️ WARNING**: This is **irreversible** and deletes all tenant data.

### Iterating Over Tenants

```ruby
# Execute code in each tenant context
Apartment::Tenant.each do |tenant_name|
  puts "Processing #{tenant_name}"
  Report.generate_monthly
end

# With specific tenant list
Apartment::Tenant.each(['acme', 'widgets']) do |tenant_name|
  DataCleanup.perform
end
```

---

## Elevators (Middleware)

Elevators automatically determine which tenant to switch to based on incoming requests.

### Available Elevators

#### Subdomain Elevator

```ruby
# config/application.rb
require 'apartment/elevators/subdomain'

module MyApp
  class Application < Rails::Application
    config.middleware.use Apartment::Elevators::Subdomain
  end
end

# config/initializers/apartment.rb
Apartment::Elevators::Subdomain.excluded_subdomains = ['www', 'admin', 'api']
```

**Behavior**:
- `acme.example.com` → switches to `acme` tenant
- `www.example.com` → stays in default tenant (excluded)

#### First Subdomain Elevator

```ruby
require 'apartment/elevators/first_subdomain'
config.middleware.use Apartment::Elevators::FirstSubdomain
```

**Behavior**:
- `api.v1.example.com` → switches to `api` tenant
- `owls.birds.animals.com` → switches to `owls` tenant

#### Domain Elevator

```ruby
require 'apartment/elevators/domain'
config.middleware.use Apartment::Elevators::Domain
```

**Behavior** (ignores 'www' and TLD):
- `example.com` → switches to `example` tenant
- `www.example.com` → switches to `example` tenant
- `api.example.com` → switches to `api` tenant

#### Host Elevator

```ruby
require 'apartment/elevators/host'
config.middleware.use Apartment::Elevators::Host

Apartment::Elevators::Host.ignored_first_subdomains = ['www']
```

**Behavior** (uses full hostname):
- `example.com` → switches to `example.com` tenant
- `www.example.com` → switches to `example.com` tenant (www ignored)

#### Host Hash Elevator

```ruby
require 'apartment/elevators/host_hash'
config.middleware.use Apartment::Elevators::HostHash, {
  'acme.customdomain.com' => 'acme_corp',
  'widgets.example.io' => 'widgets_inc'
}
```

**Behavior**: Direct hostname → tenant name mapping

#### Generic Elevator (Custom Logic)

```ruby
require 'apartment/elevators/generic'
config.middleware.use Apartment::Elevators::Generic, proc { |request|
  # Custom tenant resolution logic
  tenant = request.headers['X-Tenant-ID']
  tenant ||= request.session[:current_tenant]
  tenant || 'default'
}
```

**Or create custom elevator class**:

```ruby
# app/middleware/custom_elevator.rb
class CustomElevator < Apartment::Elevators::Generic
  def parse_tenant_name(request)
    # request is a Rack::Request object
    Company.find_by(api_key: request.headers['X-API-Key'])&.subdomain
  end
end

# config/application.rb
config.middleware.use CustomElevator
```

### Middleware Positioning

**Critical**: Elevators must be positioned correctly in the middleware stack.

```ruby
# Insert BEFORE session/authentication middleware
config.middleware.insert_before ActionDispatch::Session::CookieStore,
                                Apartment::Elevators::Subdomain

# Insert BEFORE Warden (Devise)
config.middleware.insert_before Warden::Manager,
                                Apartment::Elevators::Subdomain

# Verify middleware order
Rails.application.middleware.each do |middleware|
  puts middleware.inspect
end
```

**Why**: Tenant context must be established before session data is loaded or authentication occurs.

---

## Adapters Deep Dive

### Adapter Selection

Apartment automatically selects the appropriate adapter based on `database.yml`:

```ruby
# config/database.yml
production:
  adapter: postgresql  # → Apartment::Adapters::PostgresqlAdapter
  # adapter: mysql2    # → Apartment::Adapters::Mysql2Adapter
  # adapter: sqlite3   # → Apartment::Adapters::Sqlite3Adapter
```

**Adapter inheritance chain**:
```
AbstractAdapter (lib/apartment/adapters/abstract_adapter.rb)
├── PostgresqlAdapter (schema-based isolation)
├── Mysql2Adapter (database-based isolation)
├── Sqlite3Adapter (file-based isolation)
├── PostgisAdapter (PostgreSQL with PostGIS)
└── [JDBC variants for JRuby]
```

### PostgreSQL Schema Adapter

**Strategy**: Creates separate schemas within a single database

**Key methods**:
- `create_tenant(tenant)` → `CREATE SCHEMA "tenant_name"`
- `switch!(tenant)` → `SET search_path = "tenant_name", public`
- `drop(tenant)` → `DROP SCHEMA "tenant_name" CASCADE`

**Search path behavior**:
```sql
-- Default
SET search_path = public;

-- After switch
SET search_path = "acme_corp", public;

-- With persistent schemas
SET search_path = "acme_corp", "shared_extensions", public;
```

**Advantages**:
- ✅ High performance (single connection pool)
- ✅ Scales to hundreds of tenants
- ✅ Works on restricted environments (Heroku)
- ✅ Fast switching (simple SQL command)

**Disadvantages**:
- ❌ PostgreSQL only
- ❌ Shared connection pool (less isolation)
- ❌ Cannot easily backup single tenant

### MySQL Database Adapter

**Strategy**: Creates separate databases per tenant

**Key methods**:
- `create_tenant(tenant)` → `CREATE DATABASE \`tenant_name\``
- `switch!(tenant)` → Establishes new connection to database
- `drop(tenant)` → `DROP DATABASE \`tenant_name\``

**Advantages**:
- ✅ Complete database isolation
- ✅ Easy per-tenant backups
- ✅ Can use different MySQL instances per tenant

**Disadvantages**:
- ❌ Higher connection overhead
- ❌ Scales to fewer tenants (connection limits)
- ❌ Slower switching (connection establishment)

### SQLite Adapter

**Strategy**: Separate database files per tenant

**File location**: `db/#{tenant_name}.sqlite3`

**Advantages**:
- ✅ Complete isolation
- ✅ Excellent for testing
- ✅ Easy to inspect/backup individual tenants

**Disadvantages**:
- ❌ Not suitable for production multi-user scenarios
- ❌ File I/O overhead

---

## Excluded Models

**Purpose**: Models that exist outside tenant-specific schemas/databases.

**Common use cases**:
- User authentication (`User`, `Account`)
- Tenant registry (`Company`, `Organization`)
- Shared reference data (`Country`, `Currency`)
- System-wide settings

### Configuration

```ruby
# config/initializers/apartment.rb
Apartment.configure do |config|
  config.excluded_models = %w[User Company Role]
end
```

### What Happens

Each excluded model gets its own connection to the **default database**:

```ruby
User.establish_connection(Apartment.connection_config)
```

This ensures excluded models:
- Always query the default database/schema
- Are unaffected by `Apartment::Tenant.switch`
- Maintain separate connection pools

### Relationships with Excluded Models

**IMPORTANT**: `has_and_belongs_to_many` does NOT work with excluded models.

**Wrong**:
```ruby
class User < ApplicationRecord
  has_and_belongs_to_many :roles  # Won't work if User is excluded
end
```

**Correct**:
```ruby
class User < ApplicationRecord
  has_many :user_roles
  has_many :roles, through: :user_roles
end

class UserRole < ApplicationRecord
  belongs_to :user
  belongs_to :role
end

Apartment.configure do |config|
  config.excluded_models = %w[User UserRole Role]
end
```

---

## Callbacks

Apartment supports lifecycle callbacks via `ActiveSupport::Callbacks`.

### Available Callbacks

- `:create` - Before/after tenant creation
- `:switch` - Before/after tenant switching

### Example: Logging and Notifications

```ruby
# config/initializers/apartment.rb
require 'apartment/adapters/abstract_adapter'

module Apartment
  module Adapters
    class AbstractAdapter
      # Before tenant creation
      set_callback :create, :before do |adapter|
        Rails.logger.info "Creating tenant..."
      end

      # After tenant creation
      set_callback :create, :after do |adapter|
        tenant = Apartment::Tenant.current
        Rails.logger.info "Created tenant: #{tenant}"

        # Send notification
        AdminMailer.tenant_created(tenant).deliver_later

        # Track in analytics
        Analytics.track('tenant_created', tenant: tenant)
      end

      # Before switching
      set_callback :switch, :before do |adapter|
        Rails.logger.debug "Switching from: #{adapter.current}"
      end

      # After switching
      set_callback :switch, :after do |adapter|
        current = adapter.current
        Rails.logger.debug "Switched to: #{current}"

        # Set request context
        RequestStore.store[:current_tenant] = current

        # APM tagging
        NewRelic::Agent.add_custom_parameters(tenant: current)
      end
    end
  end
end
```

---

## Background Jobs Integration

### Sidekiq

**Installation**:
```ruby
# Gemfile
gem 'apartment-sidekiq'

# config/initializers/apartment.rb
require 'apartment/sidekiq'
```

**Behavior**:
- Automatically captures current tenant when job is enqueued
- Switches to that tenant when job executes
- Restores previous tenant after job completes

**Manual usage**:
```ruby
class ReportJob
  include Sidekiq::Worker

  def perform(report_id)
    # Already in correct tenant context
    report = Report.find(report_id)
    report.generate
  end
end

# Enqueue from tenant context
Apartment::Tenant.switch('acme_corp') do
  ReportJob.perform_async(123)  # Job will run in acme_corp context
end
```

### Other Job Frameworks

For GoodJob, Resque, DelayedJob, etc., wrap job execution manually:

```ruby
class ReportJob < ApplicationJob
  def perform(tenant_name, report_id)
    Apartment::Tenant.switch(tenant_name) do
      report = Report.find(report_id)
      report.generate
    end
  end
end
```

---

## Migrations

### Automatic Tenant Migrations

When `config.db_migrate_tenants = true`, running `rails db:migrate` will:

1. Run migrations on the default database/schema
2. Iterate through all tenants
3. Run migrations on each tenant

### Manual Tenant Migration

```bash
# Migrate all tenants
bundle exec rake apartment:migrate

# Migrate specific tenant
bundle exec rake apartment:migrate TENANT=acme_corp

# Rollback all tenants
bundle exec rake apartment:rollback

# Rollback specific tenant
bundle exec rake apartment:rollback TENANT=acme_corp
```

### Parallel Migrations

```ruby
# config/initializers/apartment.rb
config.parallel_migration_threads = 4  # Use 4 threads
```

**Benefits**: Faster migrations with many tenants
**Risks**: Database connection limits, race conditions in migration code

### Seed Data

```ruby
# config/initializers/apartment.rb
config.seed_after_create = true
config.seed_data_file = Rails.root.join('db/seeds.rb')
```

**When seeds run**:
- After `Apartment::Tenant.create`
- Within tenant context
- After all migrations complete

---

## Rake Tasks

```bash
# List all tenants
bundle exec rake apartment:tenants

# Migrate all tenants
bundle exec rake apartment:migrate

# Migrate specific tenant
bundle exec rake apartment:migrate TENANT=acme_corp

# Rollback all tenants
bundle exec rake apartment:rollback

# Rollback specific tenant
bundle exec rake apartment:rollback TENANT=acme_corp

# Seed all tenants
bundle exec rake apartment:seed

# Create new tenant
bundle exec rake apartment:create TENANT=new_tenant
```

---

## Exception Handling

### Exception Hierarchy

```
ApartmentError (StandardError)
├── AdapterNotFound - Unknown adapter in database.yml
├── FileNotFound - Missing schema file or seed file
├── TenantNotFound - Attempting to switch to non-existent tenant
└── TenantExists - Creating tenant that already exists
```

### Exception Handling Patterns

```ruby
# Tenant already exists
begin
  Apartment::Tenant.create('existing_tenant')
rescue Apartment::TenantExists => e
  Rails.logger.warn "Tenant exists: #{e.message}"
  # Handle gracefully - maybe switch instead
  Apartment::Tenant.switch('existing_tenant') { ... }
end

# Tenant not found
begin
  Apartment::Tenant.switch('nonexistent') { ... }
rescue Apartment::TenantNotFound => e
  Rails.logger.error "Tenant not found: #{e.message}"
  redirect_to root_path, alert: "Account not found"
end

# Catch all apartment errors
begin
  Apartment::Tenant.switch(params[:tenant]) do
    @records = Record.all
  end
rescue Apartment::ApartmentError => e
  Rails.logger.error "Apartment error: #{e.class} - #{e.message}"
  render json: { error: 'Tenant error' }, status: :service_unavailable
end
```

---

## Testing Considerations

### RSpec Configuration

```ruby
# spec/support/apartment.rb
RSpec.configure do |config|
  # Reset to default tenant before each test
  config.before(:each) do
    Apartment::Tenant.reset
  end

  # Clean up test tenants after suite
  config.after(:suite) do
    Apartment.tenant_names.each do |tenant|
      Apartment::Tenant.drop(tenant) if tenant.start_with?('test_')
    end
  end
end
```

### Testing Multi-Tenant Features

```ruby
RSpec.describe 'Multi-tenant reports' do
  let!(:tenant_a) { create_tenant('tenant_a') }
  let!(:tenant_b) { create_tenant('tenant_b') }

  after do
    Apartment::Tenant.drop('tenant_a')
    Apartment::Tenant.drop('tenant_b')
  end

  it 'isolates data between tenants' do
    Apartment::Tenant.switch('tenant_a') do
      Report.create!(title: 'Report A')
    end

    Apartment::Tenant.switch('tenant_b') do
      expect(Report.count).to eq(0)
    end
  end
end
```

### Database Cleaner

```ruby
# spec/support/database_cleaner.rb
RSpec.configure do |config|
  config.before(:suite) do
    DatabaseCleaner.clean_with(:truncation)
  end

  config.before(:each) do
    DatabaseCleaner.strategy = :transaction
  end

  config.before(:each, type: :feature) do
    DatabaseCleaner.strategy = :truncation
  end

  config.before(:each) do
    DatabaseCleaner.start
  end

  config.after(:each) do
    DatabaseCleaner.clean
  end
end
```

---

## Performance Optimization

### Connection Pooling

**PostgreSQL** (shared pool):
- Single connection pool for all tenants
- Fast switching via `SET search_path`
- Limited by total connections, not tenants

**MySQL** (pool per tenant):
- New connection per tenant
- Higher overhead per switch
- Can exhaust connection limits with many tenants

### Caching Strategies

```ruby
# Cache tenant list to avoid repeated DB queries
# config/initializers/apartment.rb
config.tenant_names = Rails.cache.fetch('tenant_list', expires_in: 5.minutes) do
  Company.active.pluck(:subdomain)
end

# Or use a background job to refresh
class RefreshTenantListJob < ApplicationJob
  def perform
    tenants = Company.active.pluck(:subdomain)
    Rails.cache.write('tenant_list', tenants)
  end
end
```

### Eager Loading

```ruby
# Preload tenant schemas during boot (PostgreSQL)
# config/initializers/apartment.rb
Rails.application.config.after_initialize do
  Apartment.tenant_names.each do |tenant|
    Apartment::Tenant.switch(tenant) { ActiveRecord::Base.connection }
  end
end
```

---

## Troubleshooting

### Common Issues

**Problem**: "Tenant not found" errors
**Cause**: Tenant list cache stale
**Solution**: Refresh tenant list or use dynamic tenant discovery

**Problem**: Wrong tenant data appearing
**Cause**: Elevator not positioned correctly in middleware
**Solution**: Move elevator before session/auth middleware

**Problem**: Migrations fail on tenants
**Cause**: Missing tenant or connection issues
**Solution**: Check `db_migrate_tenant_missing_strategy` setting

**Problem**: Excluded models not working
**Cause**: Models not establishing separate connections
**Solution**: Verify excluded_models configuration

### Debugging Tips

```ruby
# Check current tenant
Apartment::Tenant.current

# Inspect adapter
Apartment::Tenant.adapter.class

# Verify tenant list
Apartment.tenant_names

# Check middleware order
Rails.application.middleware.each { |m| puts m.inspect }

# Enable verbose logging
Apartment.configure do |config|
  config.active_record_log = true
end
```

---

## Migration Path to v4

**Note**: This branch (development) is v3.x. A major refactor to v4 is in progress on the `man/spec-restart` branch.

### v4 Changes (Planned)

- **Connection pool per tenant** (eliminates switching overhead)
- **Fiber/thread safety** via `ActiveSupport::CurrentAttributes`
- **Immutable connection descriptors**
- **Simpler public API**
- **Rails 7.1+ focus**

### Preparing for v4

- Use `Apartment::Tenant.switch` with blocks (avoid `switch!`)
- Minimize global state dependencies
- Ensure thread safety in custom elevators
- Review excluded model relationships

---

## Additional Resources

- **Documentation**: See `docs/` folder for concept-specific guides
- **Wiki**: https://github.com/rails-on-services/apartment/wiki
- **Issues**: https://github.com/rails-on-services/apartment/issues
- **Discussions**: https://github.com/rails-on-services/apartment/discussions
- **Original GoRails Tutorial**: https://gorails.com/episodes/multitenancy-with-apartment

---

## Contributing

This is a maintained fork under CampusESP stewardship. Contributions welcome:

1. Check existing issues/discussions
2. Write tests for new features
3. Follow existing code patterns
4. Update documentation
5. Submit PR to `development` branch

**Code Style**: Follow existing patterns, use RuboCop for linting

**Testing**: Ensure all specs pass across supported databases (PostgreSQL, MySQL, SQLite)
