# lib/apartment/ - Core Implementation Directory

This directory contains the core implementation of Apartment v3's multi-tenancy system.

## Directory Structure

```
lib/apartment/
├── adapters/              # Database-specific tenant isolation strategies
├── active_record/         # ActiveRecord patches and extensions
├── elevators/             # Rack middleware for automatic tenant switching
├── patches/               # Ruby/Rails core patches
├── tasks/                 # Rake task utilities
├── console.rb             # Rails console tenant switching utilities
├── custom_console.rb      # Enhanced console with tenant prompts
├── deprecation.rb         # Deprecation warnings configuration
├── log_subscriber.rb      # ActiveSupport instrumentation for logging
├── migrator.rb            # Tenant-specific migration runner
├── model.rb               # ActiveRecord model extensions for excluded models
├── railtie.rb             # Rails initialization and integration
├── tenant.rb              # Public API facade for tenant operations
└── version.rb             # Gem version constant
```

## Core Files

### tenant.rb - Public API Facade

**Purpose**: Main entry point for all tenant operations. Delegates to appropriate adapter.

**Key methods**:
- `create(tenant)` - Create new tenant
- `drop(tenant)` - Delete tenant
- `switch(tenant)` - Switch to tenant (block-based)
- `switch!(tenant)` - Immediate switch (no block)
- `current` - Get current tenant name
- `reset` - Return to default tenant
- `each` - Iterate over all tenants

**Adapter delegation**:
```ruby
module Apartment
  module Tenant
    extend Forwardable

    # All operations delegated to thread-local adapter
    def_delegators :adapter, :create, :drop, :switch, :current, ...

    # Adapter stored per-thread
    def adapter
      Thread.current[:apartment_adapter] ||= begin
        # Auto-detect and instantiate appropriate adapter
        send("#{config[:adapter]}_adapter", config)
      end
    end
  end
end
```

**Usage**:
```ruby
# All tenant operations go through this module
Apartment::Tenant.switch('acme') do
  User.all  # Queries acme tenant
end
```

### railtie.rb - Rails Integration

**Purpose**: Integrate Apartment with Rails initialization lifecycle.

**Responsibilities**:
1. **Configuration loading**: Load `config/initializers/apartment.rb`
2. **Adapter initialization**: Call `Apartment::Tenant.init` after Rails boot
3. **Console enhancement**: Add tenant switching helpers to Rails console
4. **Rake task loading**: Load Apartment rake tasks
5. **ActiveRecord instrumentation**: Set up logging subscriber

**Hook points**:
```ruby
module Apartment
  class Railtie < Rails::Railtie
    # After Rails initializers run
    config.after_initialize do
      Apartment::Tenant.init
    end

    # Load rake tasks
    rake_tasks do
      load 'apartment/tasks/enhancements.rake'
    end

    # Console helpers
    console do
      # Add apartment-specific commands
    end
  end
end
```

**Excluded models initialization**:
The railtie ensures excluded models establish separate connections after Rails boots but before the application serves requests.

### console.rb / custom_console.rb - Interactive Debugging

**console.rb**: Basic console helpers
**custom_console.rb**: Enhanced prompt showing current tenant

**Features**:
- Display current tenant in prompt
- Quick switching helpers
- Tenant listing commands

**Example usage**:
```ruby
# Rails console with Apartment
rails console

# Prompt shows current tenant
[public]> Apartment::Tenant.switch('acme')
[acme]> User.count
=> 42

[acme]> Apartment::Tenant.reset
[public]> User.count
=> 100
```

### migrator.rb - Tenant Migration Runner

**Purpose**: Run migrations across all tenants.

**Key functionality**:
- Detect pending migrations per tenant
- Run migrations in tenant context
- Handle migration failures gracefully
- Support parallel migration execution

**Integration with rake tasks**:
```bash
# Migrates all tenants
rake apartment:migrate

# Uses migrator.rb to:
# 1. Get list of tenants
# 2. Switch to each tenant
# 3. Run pending migrations
# 4. Handle db_migrate_tenant_missing_strategy
```

**Parallel execution**:
If `config.parallel_migration_threads > 0`, spawns threads to migrate multiple tenants concurrently.

### model.rb - Excluded Model Behavior

**Purpose**: Provide base module/behavior for excluded models.

**Functionality**:
- Establish separate connection to default database
- Bypass tenant switching
- Maintain global data across tenants

**Usage pattern**:
```ruby
# In excluded model
class Company < ApplicationRecord
  # Automatically establishes connection to default DB
  # when Apartment.excluded_models includes 'Company'
end

# These models query public/default schema always
Apartment::Tenant.switch('acme') do
  Company.all  # Still queries public.companies (excluded)
  Order.all    # Queries acme.orders (tenant-specific)
end
```

### log_subscriber.rb - Instrumentation

**Purpose**: Subscribe to ActiveSupport notifications for logging tenant operations.

**Events logged**:
- Tenant creation
- Tenant switching
- Tenant deletion
- Migration execution

**Output**:
```
[Apartment] Switched to tenant 'acme'
[Apartment] Creating tenant 'widgets'
[Apartment] Migrating tenant 'acme' (5 pending migrations)
```

**Configuration**:
```ruby
# config/initializers/apartment.rb
Apartment.configure do |config|
  config.active_record_log = true  # Enable logging
end
```

### version.rb - Version Management

**Purpose**: Define gem version constant.

```ruby
module Apartment
  VERSION = '3.2.0'
end
```

Used by gemspec and for version checking.

### deprecation.rb - Deprecation Warnings

**Purpose**: Configure ActiveSupport::Deprecation for Apartment.

**Usage**:
```ruby
module Apartment
  DEPRECATOR = ActiveSupport::Deprecation.new('4.0', 'Apartment')
end

# Emit deprecation warnings
Apartment::DEPRECATOR.warn('This feature is deprecated')
```

**Common deprecations**:
- `config.tld_length` (removed in v3)
- `Apartment::Tenant.switch!` (prefer block-based `switch`)

## Subdirectories

### adapters/

Database-specific implementations of tenant operations. See `lib/apartment/adapters/CLAUDE.md`.

**Key files**:
- `abstract_adapter.rb` - Base adapter with common logic
- `postgresql_adapter.rb` - PostgreSQL schema-based isolation
- `mysql2_adapter.rb` - MySQL database-based isolation
- `sqlite3_adapter.rb` - SQLite file-based isolation

### active_record/

ActiveRecord patches and extensions for tenant-aware behavior. See `lib/apartment/active_record/CLAUDE.md`.

**Key files**:
- `connection_handling.rb` - Patches to AR connection management
- `schema_migration.rb` - Tenant-aware schema_migrations table
- `postgresql_adapter.rb` - PostgreSQL-specific AR extensions
- `postgres/schema_dumper.rb` - Custom schema dumping (Rails 7.1+)

### elevators/

Rack middleware for automatic tenant detection. See `lib/apartment/elevators/CLAUDE.md`.

**Key files**:
- `generic.rb` - Base elevator with customizable logic
- `subdomain.rb` - Switch based on subdomain
- `domain.rb` - Switch based on domain
- `host.rb` - Switch based on full hostname
- `host_hash.rb` - Switch based on hostname→tenant mapping

### tasks/

Rake task utilities and enhancements.

**Key files**:
- `enhancements.rb` - Rake task definitions (migrate, seed, create, drop)
- `task_helper.rb` - Shared task utilities

## Data Flow

### Tenant Creation Flow

```
1. User calls: Apartment::Tenant.create('acme')
   ↓
2. tenant.rb delegates to: adapter.create('acme')
   ↓
3. Adapter (e.g., PostgresqlAdapter):
   a. Runs :before callbacks
   b. Executes: CREATE SCHEMA "acme"
   c. Switches to acme tenant
   d. Loads db/schema.rb (migrator.rb)
   e. Runs db/seeds.rb (if configured)
   f. Executes user block (if provided)
   g. Runs :after callbacks
   h. Switches back to previous tenant
   ↓
4. Returns to user code
```

### Tenant Switching Flow

```
1. User calls: Apartment::Tenant.switch('acme') { ... }
   ↓
2. tenant.rb delegates to: adapter.switch('acme') { ... }
   ↓
3. Adapter:
   a. Stores current tenant: previous = current
   b. Runs :before callbacks
   c. Executes: connect_to_new('acme')
      - PostgreSQL: SET search_path = "acme"
      - MySQL: Establish connection to acme database
   d. Runs :after callbacks
   e. Clears query cache
   f. Yields to block
   g. **ensure** block: switch!(previous)
   ↓
4. Returns to user code (tenant automatically restored)
```

### Request Processing Flow (with Elevator)

```
1. HTTP Request arrives
   ↓
2. Elevator middleware (elevators/):
   a. Extract tenant from request (parse_tenant_name)
   b. Call: Apartment::Tenant.switch(tenant) { @app.call(env) }
   ↓
3. Tenant switching (see above flow)
   ↓
4. Application processes request in tenant context
   ↓
5. Elevator ensures tenant reset after request
```

## Thread Safety

### Current Implementation (v3)

**Thread-local adapter storage**:
```ruby
Thread.current[:apartment_adapter]
```

**Implications**:
- ✅ Each thread has isolated tenant context
- ✅ Safe for multi-threaded servers (Puma)
- ✅ Safe for background jobs (Sidekiq)
- ❌ NOT fiber-safe (fibers share thread storage)
- ❌ Global mutable state within thread

**Usage in concurrent scenarios**:
```ruby
# Thread 1
Thread.new do
  Apartment::Tenant.switch('acme') do
    # Isolated to this thread
    User.all
  end
end

# Thread 2
Thread.new do
  Apartment::Tenant.switch('widgets') do
    # Isolated to this thread
    User.all
  end
end
```

## Configuration Integration

### Loading Process

```
1. Rails boots
2. config/initializers/apartment.rb loads
3. Apartment.configure { |config| ... } executes
4. Configuration stored in module instance variables
5. Railtie.after_initialize fires
6. Apartment::Tenant.init called
7. Excluded models processed
8. Adapter initialized (lazy, on first use)
```

### Configuration Access

From anywhere in the codebase:
```ruby
Apartment.tenant_names           # Get tenant list
Apartment.excluded_models        # Get excluded model list
Apartment.connection_class       # Get AR base class
Apartment.db_migrate_tenants     # Check migration setting
```

## Error Handling

### Exception Flow

```ruby
begin
  Apartment::Tenant.switch('nonexistent') do
    User.all
  end
rescue Apartment::TenantNotFound => e
  # Raised by adapter.connect_to_new
  Rails.logger.error "Tenant not found: #{e.message}"
rescue Apartment::ApartmentError => e
  # Base exception for all Apartment errors
  Rails.logger.error "Apartment error: #{e.message}"
end
```

### Automatic Cleanup

The `switch` method guarantees cleanup:
```ruby
def switch(tenant = nil)
  previous_tenant = current
  switch!(tenant)
  yield
ensure
  begin
    switch!(previous_tenant)
  rescue StandardError => _e
    reset  # Fallback to default if switch back fails
  end
end
```

## Extending Apartment

### Adding Custom Adapter

1. Create file: `lib/apartment/adapters/custom_adapter.rb`
2. Subclass `AbstractAdapter`
3. Implement required methods
4. Add factory method to `tenant.rb`

See `docs/adapters.md` for details.

### Adding Custom Elevator

1. Create file: `app/middleware/custom_elevator.rb`
2. Subclass `Apartment::Elevators::Generic`
3. Override `parse_tenant_name(request)`
4. Add to middleware stack in `config/application.rb`

See `docs/elevators.md` for details.

### Adding Custom Callbacks

```ruby
# config/initializers/apartment.rb
require 'apartment/adapters/abstract_adapter'

module Apartment
  module Adapters
    class AbstractAdapter
      set_callback :create, :after do |adapter|
        tenant = Apartment::Tenant.current
        # Custom logic after tenant creation
        AdminMailer.tenant_created(tenant).deliver_later
      end
    end
  end
end
```

## Testing Considerations

### RSpec Integration

```ruby
# spec/support/apartment.rb
RSpec.configure do |config|
  config.before(:each) do
    Apartment::Tenant.reset
  end

  config.after(:each) do
    # Ensure we're back to default
    Apartment::Tenant.reset
  end
end
```

### Creating Test Tenants

```ruby
# spec/support/apartment_helper.rb
module ApartmentHelper
  def create_test_tenant(name)
    Apartment::Tenant.create(name) unless Apartment.tenant_names.include?(name)
  end

  def drop_test_tenant(name)
    Apartment::Tenant.drop(name) if Apartment.tenant_names.include?(name)
  end
end
```

## Debugging Tips

### Enable Verbose Logging

```ruby
# config/initializers/apartment.rb
Apartment.configure do |config|
  config.active_record_log = true
end
```

### Check Current Tenant

```ruby
# In controller, console, or anywhere
puts "Current tenant: #{Apartment::Tenant.current}"
```

### Inspect Adapter

```ruby
adapter = Apartment::Tenant.adapter
puts "Adapter class: #{adapter.class.name}"
puts "Default tenant: #{adapter.default_tenant}"
```

### Verify Excluded Models

```ruby
Apartment.excluded_models.each do |model|
  klass = model.constantize
  puts "#{model}: #{klass.connection_db_config.database}"
end
```

## Common Pitfalls

1. **Not using block-based switching**: Always use `switch` with block, not `switch!`
2. **Elevator positioning**: Must be before session/auth middleware
3. **Excluded model relationships**: Use `has_many :through`, not `has_and_belongs_to_many`
4. **Thread safety assumptions**: Remember adapters are thread-local, not global
5. **Forgetting to reset**: In tests, always reset tenant in teardown

## References

- Main README: `/README.md`
- Architecture docs: `/docs/architecture.md`
- Adapter docs: `/docs/adapters.md`
- Elevator docs: `/docs/elevators.md`
- ActiveRecord connection handling: Rails guides
