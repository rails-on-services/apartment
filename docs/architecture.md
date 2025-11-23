# Apartment v3 Architecture

This document provides a deep dive into the architectural patterns and design decisions in Apartment v3.

## High-Level Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Rails Application                         │
└──────────────────┬──────────────────────────────────────────┘
                   │
                   ▼
┌─────────────────────────────────────────────────────────────┐
│                 Apartment Middleware (Elevators)             │
│  ┌──────────────┬──────────────┬──────────────┬──────────┐  │
│  │  Subdomain   │    Domain    │     Host     │  Custom  │  │
│  └──────────────┴──────────────┴──────────────┴──────────┘  │
└──────────────────┬──────────────────────────────────────────┘
                   │ Determines tenant from request
                   ▼
┌─────────────────────────────────────────────────────────────┐
│              Apartment::Tenant (Public API)                  │
│  • switch(tenant)     • create(tenant)     • drop(tenant)    │
│  • current            • reset              • each            │
└──────────────────┬──────────────────────────────────────────┘
                   │ Delegates to appropriate adapter
                   ▼
┌─────────────────────────────────────────────────────────────┐
│                    Adapter Layer                             │
│  ┌───────────────────────────────────────────────────────┐  │
│  │            AbstractAdapter (Base Logic)                │  │
│  └─────┬─────────────┬─────────────┬─────────────┬───────┘  │
│        ▼             ▼             ▼             ▼           │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌─────────────┐    │
│  │PostgreSQL│ │  MySQL2  │ │  SQLite3 │ │  JDBC/etc   │    │
│  └──────────┘ └──────────┘ └──────────┘ └─────────────┘    │
└──────────────────┬──────────────────────────────────────────┘
                   │ Database-specific operations
                   ▼
┌─────────────────────────────────────────────────────────────┐
│                    Database Layer                            │
│  ┌───────────────────────────────────────────────────────┐  │
│  │  PostgreSQL Schemas  │  MySQL Databases  │  SQLite   │  │
│  │  ┌───────────────┐   │  ┌─────────────┐  │  Files    │  │
│  │  │ public        │   │  │ acme_corp   │  │  ┌─────┐ │  │
│  │  │ acme_corp     │   │  │ widgets_inc │  │  │acme │ │  │
│  │  │ widgets_inc   │   │  │ startup_co  │  │  └─────┘ │  │
│  │  └───────────────┘   │  └─────────────┘  │          │  │
│  └───────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

## Core Design Patterns

### 1. Adapter Pattern

**Problem**: Different databases have different mechanisms for multi-tenancy.

**Solution**: Abstract common tenant operations behind a unified interface, with database-specific implementations.

```ruby
# Unified interface (AbstractAdapter)
class AbstractAdapter
  def create(tenant)
    # Common logic: callbacks, schema import, seeding
  end

  def switch!(tenant)
    # Database-specific implementation in subclass
  end

  def drop(tenant)
    # Database-specific implementation in subclass
  end
end

# PostgreSQL implementation
class PostgresqlAdapter < AbstractAdapter
  def switch!(tenant)
    # SET search_path = "tenant_name", public
  end
end

# MySQL implementation
class Mysql2Adapter < AbstractAdapter
  def switch!(tenant)
    # Establish new connection to different database
  end
end
```

**Benefits**:
- Single public API (`Apartment::Tenant`)
- Database-specific optimizations
- Easy to add new database support

### 2. Thread-Local Storage Pattern

**Problem**: Multiple concurrent requests need isolated tenant contexts.

**Solution**: Store adapter instance in `Thread.current`.

```ruby
module Apartment
  module Tenant
    def adapter
      Thread.current[:apartment_adapter] ||= begin
        # Create adapter based on database config
        adapter_method = "#{config[:adapter]}_adapter"
        send(adapter_method, config)
      end
    end
  end
end
```

**Key characteristics**:
- Each thread gets its own adapter instance
- Tenant switching is isolated per-thread
- Safe for multi-threaded servers (Puma, Falcon)
- Safe for background jobs (Sidekiq)

**Limitations**:
- NOT fiber-safe (fibers share thread-local storage)
- Global mutable state within thread

### 3. Delegation Pattern

**Problem**: Simplify public API while maintaining flexibility.

**Solution**: `Apartment::Tenant` delegates to the current adapter.

```ruby
module Apartment
  module Tenant
    extend Forwardable

    # Delegate all operations to adapter
    def_delegators :adapter,
      :create, :drop, :switch, :switch!,
      :current, :each, :reset, :seed
  end
end

# Usage
Apartment::Tenant.switch('acme')  # Calls adapter.switch('acme')
```

**Benefits**:
- Simple, consistent API
- Adapter swapping is transparent
- Easy to test (can mock adapter)

### 4. Callback Pattern

**Problem**: Users need to execute custom logic during tenant operations.

**Solution**: `ActiveSupport::Callbacks` for lifecycle hooks.

```ruby
class AbstractAdapter
  include ActiveSupport::Callbacks
  define_callbacks :create, :switch

  def create(tenant)
    run_callbacks :create do
      # Actual creation logic
    end
  end

  def switch!(tenant)
    run_callbacks :switch do
      # Actual switching logic
    end
  end
end

# User adds custom callbacks
AbstractAdapter.set_callback :create, :after do
  Rails.logger.info "Created tenant: #{Apartment::Tenant.current}"
end
```

**Use cases**:
- Logging tenant operations
- Sending notifications
- Analytics tracking
- APM integration

### 5. Strategy Pattern (Elevators)

**Problem**: Different applications need different tenant resolution strategies.

**Solution**: Pluggable elevator implementations.

```ruby
# Base strategy
class Generic
  def call(env)
    tenant = parse_tenant_name(Rack::Request.new(env))
    Apartment::Tenant.switch(tenant) do
      @app.call(env)
    end
  end

  def parse_tenant_name(request)
    # Override in subclasses
  end
end

# Specific strategies
class Subdomain < Generic
  def parse_tenant_name(request)
    request.subdomain
  end
end

class Domain < Generic
  def parse_tenant_name(request)
    request.domain
  end
end
```

**Benefits**:
- Easy to add custom strategies
- Composable (can use multiple elevators)
- Testable in isolation

## Component Interaction Flow

### Request Processing

```
1. Request arrives → http://acme.example.com/orders

2. Elevator middleware intercepts
   ├─ Extract subdomain: "acme"
   ├─ Check exclusions (not in excluded_subdomains)
   └─ Call Apartment::Tenant.switch('acme')

3. Apartment::Tenant.switch
   ├─ Get current adapter (thread-local)
   ├─ Store previous tenant
   ├─ Call adapter.switch!('acme')
   │  ├─ [PostgreSQL] SET search_path = "acme", public
   │  └─ [MySQL] Establish connection to acme database
   └─ Execute application code in block

4. Application processes request
   ├─ All ActiveRecord queries use tenant context
   ├─ User.all → SELECT FROM acme.users (PostgreSQL)
   ├─          → SELECT FROM users (in acme database, MySQL)
   └─ Excluded models use separate connections

5. Elevator ensures cleanup
   └─ Apartment::Tenant.switch back to previous tenant
```

### Tenant Creation

```
1. Apartment::Tenant.create('new_tenant')

2. Adapter.create
   ├─ Run :before callbacks
   ├─ Create schema/database
   │  ├─ [PostgreSQL] CREATE SCHEMA "new_tenant"
   │  └─ [MySQL] CREATE DATABASE `new_tenant`
   ├─ Switch to new tenant
   ├─ Import schema (db/schema.rb)
   │  ├─ Load schema file
   │  └─ Execute CREATE TABLE statements
   ├─ Seed data (if configured)
   │  └─ Execute db/seeds.rb in tenant context
   ├─ Execute block (if provided)
   └─ Run :after callbacks

3. Switch back to previous tenant
```

## Data Flow

### PostgreSQL Schema Strategy

```
Connection Pool (shared across tenants)
  ↓
Connection #1 → SET search_path = "acme"
  ↓
  Query: SELECT * FROM users
  ↓
  Resolved: SELECT * FROM acme.users
  ↓
  Result: acme tenant data

Connection #2 → SET search_path = "widgets"
  ↓
  Query: SELECT * FROM orders
  ↓
  Resolved: SELECT * FROM widgets.orders
  ↓
  Result: widgets tenant data
```

**Key insight**: Same connection pool, different schema path per query.

### MySQL Database Strategy

```
Connection Pool (per database)
  ↓
Pool for 'acme'     Pool for 'widgets'
  ↓                     ↓
Connection to acme   Connection to widgets
  ↓                     ↓
Query: SELECT *      Query: SELECT *
FROM users           FROM orders
  ↓                     ↓
acme.users           widgets.orders
```

**Key insight**: Separate connection pools per tenant.

## Thread Safety

### Current Implementation (v3)

```ruby
# Thread-local adapter storage
Thread.current[:apartment_adapter] = PostgresqlAdapter.new

# Each thread has isolated tenant context
Thread 1: Apartment::Tenant.current → "acme"
Thread 2: Apartment::Tenant.current → "widgets"
```

**Safe scenarios**:
- ✅ Multi-threaded web servers (Puma, Falcon)
- ✅ Background job workers (Sidekiq with threading)
- ✅ Concurrent requests to different tenants

**Unsafe scenarios**:
- ❌ Fibers (share thread-local storage)
- ❌ Async frameworks relying on fiber switching
- ❌ Manual thread management with shared state

### Future v4 Implementation

```ruby
# Fiber-safe via CurrentAttributes
class Apartment::Current < ActiveSupport::CurrentAttributes
  attribute :tenant
end

# Automatically resets per request/job
# Safe for async frameworks
```

## Memory Management

### PostgreSQL (Shared Pool)

```
Memory usage = Base connection pool + Schema metadata

Tenants: 100
Connection pool: 5 connections
Memory: ~50MB (relatively constant)
```

**Scaling characteristics**:
- Memory grows slowly with tenant count
- Primarily schema metadata (table definitions)
- Connection pool size independent of tenant count

### MySQL (Pool Per Tenant)

```
Memory usage = (Connection pool size) × (Number of active tenants)

Tenants: 100
Connection pool per tenant: 5
Active tenants (cached): 20
Memory: 20 × 5 × ~10MB = ~1GB
```

**Scaling characteristics**:
- Memory grows with concurrent active tenants
- Can implement LRU cache for connection pools
- Must monitor connection limits

## Excluded Models Architecture

### Connection Isolation

```
Default Connection Class (Apartment.connection_class)
├─ Normal models (tenant-specific)
│  ├─ User (excluded)
│  ├─ Company (excluded)
│  └─ Role (excluded)
│
└─ All other models
   ├─ Order (tenant-scoped)
   ├─ Product (tenant-scoped)
   └─ Invoice (tenant-scoped)

Excluded models establish separate connections:
User.establish_connection(default_config)
```

**Flow**:
```
1. Apartment initializes
2. For each excluded model:
   ├─ Model.constantize
   └─ Model.establish_connection(default_config)
3. Excluded models now bypass tenant switching
```

**Query behavior**:
```ruby
Apartment::Tenant.switch('acme') do
  Order.all    # → SELECT FROM acme.orders (tenant-specific)
  User.all     # → SELECT FROM public.users (excluded)
end
```

## Configuration Deep Dive

### tenant_names Resolution

```ruby
# Static array
config.tenant_names = ['acme', 'widgets']
# → Returns: ['acme', 'widgets']

# Callable (lambda/proc)
config.tenant_names = -> { Company.pluck(:subdomain) }
# → Executes lambda, returns: ['acme', 'widgets', 'startup']

# Hash (tenant → config mapping)
config.tenant_names = {
  'acme' => { host: 'db1.example.com' },
  'widgets' => { host: 'db2.example.com' }
}
# → Multi-database support
```

### Schema Import Process

```
1. Determine schema source
   ├─ config.database_schema_file (default: db/schema.rb)
   └─ Verify file exists

2. Switch to tenant context

3. Silence ActiveRecord logging (optional)

4. Load schema file
   ├─ Executes Ruby code (schema.rb)
   └─ Creates tables, indexes, constraints

5. Seed data (if configured)
   ├─ Executes db/seeds.rb
   └─ Within tenant context

6. Switch back to previous tenant
```

## Extension Points

### Custom Adapter

```ruby
# lib/apartment/adapters/custom_adapter.rb
module Apartment
  module Adapters
    class CustomAdapter < AbstractAdapter
      def create_tenant(tenant)
        # Custom creation logic
      end

      def connect_to_new(tenant)
        # Custom switching logic
      end

      def drop_command(conn, tenant)
        # Custom drop logic
      end
    end
  end
end

# Register adapter
module Apartment
  module Tenant
    def custom_adapter(config)
      Adapters::CustomAdapter.new(config)
    end
  end
end
```

### Custom Elevator

```ruby
# app/middleware/api_key_elevator.rb
class ApiKeyElevator < Apartment::Elevators::Generic
  def parse_tenant_name(request)
    api_key = request.headers['X-API-Key']
    return nil unless api_key

    # Lookup tenant from API key
    ApiKey.find_by(key: api_key)&.tenant_name
  end
end

# config/application.rb
config.middleware.use ApiKeyElevator
```

## Performance Characteristics

### PostgreSQL Schema Switching

**Latency**: < 1ms (SQL command execution)
**Throughput**: Limited by connection pool size
**Scalability**: 100+ tenants with no performance degradation

### MySQL Database Switching

**Latency**: ~10-50ms (connection establishment)
**Throughput**: Limited by connection pool count × tenants
**Scalability**: 10-20 active tenants before connection limits

### SQLite File Switching

**Latency**: ~5-20ms (file I/O + connection establishment)
**Throughput**: Limited by disk I/O
**Scalability**: Not recommended for production multi-user

## Error Handling Strategy

### Exception Hierarchy Design

```
ApartmentError (StandardError)
  ├─ AdapterNotFound
  │  └─ Raised when database adapter not supported
  ├─ FileNotFound
  │  └─ Raised when schema/seed file missing
  ├─ TenantNotFound
  │  └─ Raised when switching to non-existent tenant
  └─ TenantExists
     └─ Raised when creating duplicate tenant
```

### Recovery Patterns

```ruby
# Graceful degradation
def switch!(tenant)
  previous = current
  connect_to_new(tenant)
rescue TenantNotFound
  # Attempt to fall back
  connect_to_new(default_tenant)
ensure
  # Always ensure valid connection
end
```

## Limitations & Trade-offs

### Current Architecture

**Limitations**:
- Thread-local storage (not fiber-safe)
- Global mutable state within threads
- Switching overhead (especially MySQL)
- Connection pool management complexity

**Trade-offs**:
- **Flexibility** ↔ **Complexity**: Supporting multiple databases adds complexity
- **Performance** ↔ **Isolation**: PostgreSQL is faster but less isolated than MySQL
- **Simplicity** ↔ **Features**: Rich feature set increases maintenance burden

### v4 Direction

Addressing limitations through:
- **Connection pool per tenant** (eliminates switching)
- **`CurrentAttributes`** (fiber-safe, cleaner state management)
- **Immutable connection descriptors** (thread-safe by design)
- **Simplified public API** (reduce surface area)

## References

- **Thread-local storage**: Ruby's `Thread.current` hash
- **ActiveSupport::Callbacks**: Rails callback framework
- **Adapter pattern**: Gang of Four design patterns
- **Connection pooling**: ActiveRecord connection management
- **Middleware pattern**: Rack middleware specification
