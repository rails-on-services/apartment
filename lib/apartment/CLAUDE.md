# lib/apartment/ - Core Implementation Directory

This directory contains the core implementation of Apartment v3's multi-tenancy system.

## Directory Structure

```
lib/apartment/
├── adapters/              # Database-specific tenant isolation strategies (see CLAUDE.md)
├── active_record/         # ActiveRecord patches and extensions
├── elevators/             # Rack middleware for automatic tenant switching (see CLAUDE.md)
├── patches/               # Ruby/Rails core patches
├── tasks/                 # Rake task utilities, parallel migrations (see CLAUDE.md)
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

**Adapter delegation pattern**: Uses `Forwardable` to delegate all operations to thread-local adapter instance. See delegation setup in `tenant.rb`.

**Thread-local storage**: Each thread maintains its own adapter via `Thread.current[:apartment_adapter]`. See `Apartment::Tenant.adapter` method for auto-detection logic.

### railtie.rb - Rails Integration

**Purpose**: Integrate Apartment with Rails initialization lifecycle.

**Responsibilities**:
1. **Configuration loading**: Load `config/initializers/apartment.rb`
2. **Adapter initialization**: Call `Apartment::Tenant.init` after Rails boot
3. **Console enhancement**: Add tenant switching helpers to Rails console
4. **Rake task loading**: Load Apartment rake tasks
5. **ActiveRecord instrumentation**: Set up logging subscriber

**Key integration points**: See Rails integration hooks in `railtie.rb` (`after_initialize`, `rake_tasks`, `console`).

**Excluded models initialization**: The railtie ensures excluded models establish separate connections after Rails boots but before the application serves requests. See excluded model setup in `railtie.rb`.

### console.rb / custom_console.rb - Interactive Debugging

**console.rb**: Basic console helpers
**custom_console.rb**: Enhanced prompt showing current tenant

**Features**:
- Display current tenant in prompt
- Quick switching helpers
- Tenant listing commands

**Implementation**: See `console.rb` and `custom_console.rb` for prompt customization and helper methods.

### migrator.rb - Tenant Migration Runner

**Purpose**: Run migrations across all tenants.

**Key functionality**:
- Detect pending migrations per tenant
- Run migrations in tenant context
- Handle migration failures gracefully
- Support parallel migration execution

**Integration**: Used by `rake apartment:migrate` task. See migration coordination logic in `migrator.rb` and task definitions in `tasks/enhancements.rake`.

**Parallel execution**: If `config.parallel_migration_threads > 0`, spawns threads to migrate multiple tenants concurrently. See parallel execution logic in `migrator.rb`.

### model.rb - Excluded Model Behavior

**Purpose**: Provide base module/behavior for excluded models.

**Functionality**:
- Establish separate connection to default database
- Bypass tenant switching
- Maintain global data across tenants

**Behavior**: When a model is in `Apartment.excluded_models`, it automatically establishes connection to default database and bypasses tenant switching. See connection handling in `model.rb` and `AbstractAdapter#process_excluded_models`.

### log_subscriber.rb - Instrumentation

**Purpose**: Subscribe to ActiveSupport notifications for logging tenant operations.

**Events logged**:
- Tenant creation
- Tenant switching
- Tenant deletion
- Migration execution

**Configuration**: Set `config.active_record_log = true` to enable. See event subscriptions in `log_subscriber.rb` and configuration options in `lib/apartment.rb`.

### version.rb - Version Management

**Purpose**: Define gem version constant. Used by gemspec and for version checking. See `version.rb`.

### deprecation.rb - Deprecation Warnings

**Purpose**: Configure ActiveSupport::Deprecation for Apartment.

**Implementation**: Sets up deprecation warnings targeting v4.0. See `deprecation.rb` for DEPRECATOR constant.

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

1. User calls `Apartment::Tenant.create('acme')`
2. Delegates to adapter which executes callbacks, creates schema/database, imports schema, optionally runs seeds
3. Returns to user code

**See**: `Apartment::Tenant.create` and `AbstractAdapter#create` for orchestration.

### Tenant Switching Flow

1. User calls `Apartment::Tenant.switch('acme') { ... }`
2. Adapter stores current tenant, switches connection, yields to block, ensures rollback in ensure clause
3. Returns to user code with tenant automatically restored

**See**: `AbstractAdapter#switch` method for implementation.

### Request Processing Flow (with Elevator)

1. HTTP Request arrives
2. Elevator extracts tenant, calls `Apartment::Tenant.switch`
3. Application processes in tenant context
4. Elevator ensures tenant reset

**See**: `elevators/generic.rb` for middleware pattern.

## Thread Safety

### Current Implementation (v3)

**Thread-local adapter storage**: Uses `Thread.current[:apartment_adapter]` for isolation.

**Implications**:
- ✅ Each thread has isolated tenant context
- ✅ Safe for multi-threaded servers (Puma)
- ✅ Safe for background jobs (Sidekiq)
- ❌ NOT fiber-safe (fibers share thread storage)
- ❌ Global mutable state within thread

**See**: `Apartment::Tenant.adapter` method for thread-local implementation.

## Configuration Integration

### Loading Process

1. Rails boots
2. `config/initializers/apartment.rb` loads
3. `Apartment.configure` executes
4. Configuration stored in module instance variables
5. `Railtie.after_initialize` fires
6. `Apartment::Tenant.init` called
7. Excluded models processed
8. Adapter initialized (lazy, on first use)

**See**: Configuration methods in `lib/apartment.rb` and initialization hooks in `railtie.rb`.

### Configuration Access

Available configuration methods: `Apartment.tenant_names`, `Apartment.excluded_models`, `Apartment.connection_class`, `Apartment.db_migrate_tenants`. See `lib/apartment.rb` for all configuration options.

## Error Handling

### Exception Hierarchy

- `Apartment::ApartmentError` - Base exception for all Apartment errors
- `Apartment::TenantNotFound` - Raised when switching to nonexistent tenant
- `Apartment::TenantExists` - Raised when creating duplicate tenant

**See**: Adapter `connect_to_new` methods raise `TenantNotFound`. See `AbstractAdapter#switch` for error handling.

### Automatic Cleanup

The `switch` method guarantees cleanup via ensure block, falling back to default tenant if rollback fails. See `AbstractAdapter#switch` for implementation.

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

Use ActiveSupport::Callbacks to hook into `:create` and `:switch` events. See callback definitions in `AbstractAdapter` and README.md for configuration examples.

## Testing Considerations

### RSpec Integration

Always reset tenant context in before/after hooks to prevent test isolation issues. See `spec/support/` for helper modules and `spec/spec_helper.rb` for configuration patterns.

### Creating Test Tenants

Create helpers for tenant lifecycle management to avoid duplication. See `spec/support/apartment_helper.rb` for patterns.

## Debugging Tips

### Enable Verbose Logging

Set `config.active_record_log = true` in initializer. See logging configuration in `lib/apartment.rb`.

### Check Current Tenant

Use `Apartment::Tenant.current` to inspect current tenant context.

### Inspect Adapter

Access `Apartment::Tenant.adapter` to inspect adapter class and configuration.

### Verify Excluded Models

Iterate `Apartment.excluded_models` and check each model's connection configuration.

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
