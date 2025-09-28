# lib/CLAUDE.md - Apartment Implementation Context

This directory contains the core implementation of the Apartment gem's connection-pool-per-tenant architecture.

## Directory Structure

### Core Files

- **`apartment.rb`** - Main module, configuration, and Zeitwerk setup
- **`apartment/config.rb`** - Configuration management and validation
- **`apartment/current.rb`** - Thread-safe tenant tracking (`CurrentAttributes`)
- **`apartment/tenant.rb`** - Public API for tenant switching operations

### Connection Management

- **`apartment/connection_adapters/`** - Custom Rails connection handling
  - `connection_handler.rb` - Tenant-aware connection pool management
  - `tenant_connection_descriptor.rb` - Immutable tenant-connection binding
  - `pool_manager.rb` - Connection pool lifecycle management
  - `pool_config.rb` - Tenant-specific pool configuration

### Database Strategies

- **`apartment/database_configurations.rb`** - Multi-strategy tenant resolution
- **`apartment/configs/`** - Database-specific configuration classes
  - `postgresql_config.rb` - PostgreSQL schema isolation settings
  - `mysql_config.rb` - MySQL database-per-tenant settings

### Rails Integration

- **`apartment/railtie.rb`** - Rails initialization and hooks
- **`apartment/patches/connection_handling.rb`** - ActiveRecord integration

## Core Architecture

### Connection Pool Design

The gem implements **immutable connection pools per tenant**:

```ruby
# Each tenant gets a dedicated connection pool
"ActiveRecord::Base[tenant1]" => PoolManager.new
"ActiveRecord::Base[tenant2]" => PoolManager.new
```

**Key Benefits:**
- Zero connection switching overhead
- Complete tenant isolation
- Thread/fiber safety by design
- Memory efficient pool reuse

### Thread Safety Implementation

Uses `ActiveSupport::CurrentAttributes` for fiber/thread isolation:

```ruby
class Apartment::Current < ActiveSupport::CurrentAttributes
  attribute :tenant
end
```

**Guarantees:**
- Automatic reset per request/job
- No global state contamination
- Exception-safe cleanup

### Tenant Strategy Resolution

Database-agnostic tenant configuration via strategy pattern:

```ruby
case config.tenant_strategy
when :schema
  # PostgreSQL schema isolation
when :database_per_tenant
  # Complete database separation
when :database_config
  # Custom per-tenant configurations
end
```

## Implementation Patterns

### Configuration Pattern

Thread-safe, validated configuration:

```ruby
Apartment.configure do |config|
  config.tenant_strategy = :schema
  config.tenants_provider = -> { Tenant.active.pluck(:name) }
  config.default_tenant = "public"
end
```

### Tenant Switching Pattern

Block-scoped with automatic cleanup:

```ruby
def switch(tenant = nil, &block)
  previous_tenant = current || default_tenant
  Current.tenant = tenant || default_tenant
  connection_class.with_connection(&block)
ensure
  Current.tenant = previous_tenant
end
```

### Connection Descriptor Pattern

Immutable tenant-connection binding:

```ruby
class TenantConnectionDescriptor < SimpleDelegator
  def initialize(base_class, tenant = nil)
    super(base_class)
    @tenant = base_class.try(:pinned_tenant) || tenant
    @name = "#{base_class.name}[#{@tenant}]"
  end
end
```

## Database Strategy Implementation

### PostgreSQL Schema Strategy (`:schema`)

- **Mechanism**: `SET search_path = "tenant_name", public`
- **Isolation**: Schema-level separation
- **Performance**: Optimal for high tenant count (100+)
- **Configuration**: Per-connection schema path setting

### MySQL Database Strategy (`:database_per_tenant`)

- **Mechanism**: Separate database per tenant
- **Isolation**: Complete database separation
- **Performance**: Moderate tenant count (10-50)
- **Configuration**: Database name per tenant

### SQLite Strategy

- **Mechanism**: In-memory or file-based databases
- **Isolation**: Complete database separation
- **Performance**: Excellent for testing
- **Configuration**: Database path per tenant

## Code Organization Principles

### Separation of Concerns

1. **Configuration** (`config.rb`) - Settings and validation
2. **Current State** (`current.rb`) - Thread-safe tenant tracking
3. **Public API** (`tenant.rb`) - User-facing operations
4. **Connection Management** (`connection_adapters/`) - Low-level pool handling
5. **Database Strategies** (`database_configurations.rb`) - Multi-DB support

### Rails Integration

- **Minimal Patches**: Only extend where necessary
- **Native APIs**: Build on Rails connection handling
- **Zeitwerk Friendly**: Proper autoloading and inflections
- **Railtie Integration**: Standard Rails initialization

### Error Handling

- **Validation Early**: Configuration errors at startup
- **Exception Safety**: Guaranteed cleanup in `ensure` blocks
- **Graceful Degradation**: Fallback to default tenant
- **Clear Messages**: Helpful error descriptions

## Extension Points

### Adding New Database Strategies

1. Extend `TENANT_STRATEGIES` in `config.rb`
2. Add resolution logic in `database_configurations.rb`
3. Create strategy-specific config class in `configs/`
4. Add tests for new strategy

### Custom Connection Handling

1. Extend `ConnectionHandler` for specialized behavior
2. Override `establish_connection` for custom logic
3. Implement custom `PoolManager` if needed
4. Maintain thread safety guarantees

### Middleware Integration

1. Use `Apartment::Tenant.switch` in Rack middleware
2. Ensure proper cleanup in `ensure` blocks
3. Handle tenant resolution errors gracefully
4. Consider performance implications

## Performance Considerations

### Memory Management

- **Pool Reuse**: Same tenant reuses identical pool object
- **Lazy Creation**: Pools created only when needed
- **Bounded Growth**: Limited by unique tenant count
- **GC Friendly**: No circular references

### Concurrency Optimization

- **Lock-Free Reads**: Current tenant access without locks
- **Minimal Contention**: Pool creation synchronized only
- **Thread Isolation**: No shared mutable state
- **Exception Safety**: Cleanup guaranteed under all conditions

### Database-Specific Optimizations

- **PostgreSQL**: Single connection pool, schema switching
- **MySQL**: Multiple pools, database isolation
- **SQLite**: In-memory optimization for testing

## Development Guidelines

### Code Style

- Follow existing patterns for consistency
- Use meaningful variable and method names
- Document complex logic with comments
- Maintain thread safety in all operations

### Testing Requirements

- Write database-agnostic tests when possible
- Include thread safety validation
- Test exception scenarios
- Verify memory behavior under load

### Performance Requirements

- Maintain sub-millisecond switching for cached pools
- Support 50+ concurrent tenants without degradation
- Ensure memory stability under rapid switching
- Provide graceful behavior under high load