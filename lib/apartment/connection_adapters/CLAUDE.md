# lib/apartment/connection_adapters/CLAUDE.md - Connection Pool Architecture

This directory implements the core **connection-pool-per-tenant architecture** that makes Apartment's multi-tenancy both performant and thread-safe.

## Core Innovation: Immutable Tenant-Connection Binding

Unlike traditional connection switching approaches, this architecture creates **permanent bindings** between tenants and connection pools.

### Key Files

- **`connection_handler.rb`** - Custom Rails ConnectionHandler with tenant awareness
- **`pool_manager.rb`** - Lifecycle management for tenant connection pools
- **`pool_config.rb`** - Tenant-specific pool configuration wrapper
- **`connection_pool.rb`** - Extended Rails ConnectionPool with tenant context
- **`connection_counter.rb`** - Connection usage tracking and monitoring

## Architecture Principles

### 1. Immutable Pool-Per-Tenant

```ruby
# Traditional approach (BAD - switching overhead)
switch_to_tenant("tenant1") # SET search_path, connection juggling
User.all                    # Query with overhead
reset_tenant()             # More overhead

# Our approach (GOOD - zero switching overhead)
Apartment::Tenant.switch("tenant1") do
  User.all  # Direct pool access, zero overhead
end
```

**Benefits:**
- ✅ **Zero switching overhead** - no SET statements per query
- ✅ **Thread safety** - pools completely isolated
- ✅ **Memory efficiency** - pools reused across requests
- ✅ **Exception safety** - automatic cleanup guaranteed

### 2. TenantConnectionDescriptor Pattern

The core innovation that enables tenant-specific connection pools:

```ruby
class TenantConnectionDescriptor < SimpleDelegator
  def initialize(base_class, tenant = nil)
    super(base_class)
    @tenant = base_class.try(:pinned_tenant) || tenant
    @name = "#{base_class.name}[#{@tenant}]"
  end
end
```

**Key Features:**
- **Unique Identification**: `"ActiveRecord::Base[tenant1]"` vs `"ActiveRecord::Base[tenant2]"`
- **Delegation**: Transparent proxy to original model class
- **Pinned Tenant Support**: Models can force specific tenants
- **Rails Compatible**: Works seamlessly with existing Rails connection APIs

### 3. Custom ConnectionHandler

Extends Rails' native connection handling without breaking compatibility:

```ruby
class ConnectionHandler < ActiveRecord::ConnectionAdapters::ConnectionHandler
  def establish_connection(config, owner_name:, role:, shard:, tenant: nil)
    # Create tenant-specific pool using TenantConnectionDescriptor
    owner_name = determine_owner_name(owner_name, config, tenant)

    # Rest of Rails native logic with tenant awareness
  end
end
```

**Extensions:**
- **Tenant-Aware Pool Creation**: Automatic tenant binding during establishment
- **Pool Isolation**: Complete separation between tenant pools
- **Rails Native**: Builds on documented Rails APIs
- **Backwards Compatible**: Existing Rails code works unchanged

## Implementation Details

### Connection Pool Lifecycle

1. **Pool Creation** (lazy, on-demand):
   ```ruby
   Apartment::Tenant.switch!("new_tenant")
   # Creates: connection_name_to_pool_manager["ActiveRecord::Base[new_tenant]"]
   ```

2. **Pool Reuse** (automatic):
   ```ruby
   Apartment::Tenant.switch!("existing_tenant")
   # Reuses existing pool object - same object_id
   ```

3. **Pool Isolation** (by design):
   ```ruby
   # These are completely separate pool objects
   pool1 = get_pool_for("tenant1")  # Pool A
   pool2 = get_pool_for("tenant2")  # Pool B
   # pool1.object_id != pool2.object_id
   ```

### Database Strategy Integration

The connection adapters work with all database strategies:

**PostgreSQL Schema Strategy:**
```ruby
# Pool configured with: schema_search_path = "tenant_name"
# One-time setup, then direct pool access
```

**Database-Per-Tenant Strategy:**
```ruby
# Pool configured with: database = "tenant_database"
# Complete database isolation per pool
```

**Custom Configuration Strategy:**
```ruby
# Pool configured with: custom config hash
# Flexible per-tenant database settings
```

### Thread Safety Implementation

**Pool Manager Isolation:**
```ruby
# Each tenant gets isolated pool manager
connection_name_to_pool_manager = {
  "ActiveRecord::Base[tenant1]" => PoolManager.new,
  "ActiveRecord::Base[tenant2]" => PoolManager.new
}
```

**CurrentAttributes Integration:**
```ruby
def retrieve_connection_pool(connection_name, tenant: nil)
  # Uses Apartment::Current.tenant for thread-safe tenant resolution
  tenant ||= Apartment::Current.tenant
  pool_manager = get_pool_manager(connection_name, tenant: tenant)
  # ...
end
```

## Performance Optimizations

### 1. Connection Pool Caching

```ruby
# O(1) pool lookup after initial creation
@connection_name_to_pool_manager[tenant_key] ||= create_new_pool
```

### 2. Lazy Pool Creation

Pools created only when actually accessed:
- **Memory Efficient**: Only active tenants consume memory
- **Fast Startup**: No upfront pool creation overhead
- **Scale Friendly**: Supports hundreds of potential tenants

### 3. Pool Reuse Strategy

Same tenant always gets same pool object:
- **Cache Friendly**: JIT compiler optimizations
- **Memory Stable**: No pool object churn
- **GC Efficient**: Minimal allocation pressure

## Error Handling & Edge Cases

### Pool Creation Failures

```ruby
def establish_connection(config, **options)
  # Validate tenant exists
  # Handle database connection errors
  # Provide clear error messages
rescue ActiveRecord::DatabaseConnectionError => e
  # Enhanced error with tenant context
  raise ConnectionError, "Failed to connect for tenant #{tenant}: #{e.message}"
end
```

### Cleanup on Exceptions

```ruby
def retrieve_connection_pool(connection_name, strict: false, **options)
  pool = find_or_create_pool(connection_name, **options)

  if strict && !pool
    # Clear error message with tenant context
    raise ActiveRecord::ConnectionNotDefined.new(
      message: "No connection defined for #{tenant}",
      tenant: tenant
    )
  end

  pool
end
```

### Race Condition Prevention

- **Synchronized Pool Creation**: Thread-safe pool manager assignment
- **Atomic Pool Lookup**: Consistent pool references across threads
- **Exception Safety**: Cleanup guaranteed even on errors

## Integration with Rails

### Minimal Monkey Patching

We override only essential methods and delegate to parent:

```ruby
def establish_connection(config, **options)
  # Add tenant awareness
  owner_name = determine_owner_name(owner_name, config, tenant)

  # Delegate to parent implementation
  super(config, owner_name: owner_name, **options)
end
```

### Rails Version Compatibility

Handles Rails version differences gracefully:

```ruby
if ActiveRecord.version < Gem::Version.new('7.2.0')
  pool.connection
else
  pool.lease_connection
end
```

### ActiveRecord Integration

Works seamlessly with existing ActiveRecord features:
- **Migrations**: Run per tenant using tenant switching
- **Multiple Databases**: Compatible with Rails multi-DB features
- **Connection Pooling**: Extends rather than replaces Rails pools
- **Monitoring**: Hooks into Rails connection monitoring

## Debugging & Monitoring

### Connection Pool Inspection

```ruby
# View all active pools
ActiveRecord::Base.connection_handler.instance_variable_get(:@connection_name_to_pool_manager)

# Check specific tenant pool
Apartment::Tenant.switch!("debug_tenant")
ActiveRecord::Base.connection_pool.connections.count
```

### Performance Monitoring

```ruby
# Track pool creation
ActiveSupport::Notifications.subscribe('!connection.active_record') do |name, start, finish, id, payload|
  puts "Pool created for tenant: #{payload[:tenant]}"
end
```

### Memory Usage Tracking

```ruby
# Monitor pool manager growth
handler = ActiveRecord::Base.connection_handler
pool_count = handler.instance_variable_get(:@connection_name_to_pool_manager).size
```

## Development Guidelines

### Adding New Features

1. **Maintain Thread Safety**: All operations must be thread-safe
2. **Preserve Rails Compatibility**: Build on documented Rails APIs
3. **Exception Safety**: Guarantee cleanup in all scenarios
4. **Performance Aware**: Consider impact on pool creation/lookup

### Testing Connection Adapters

1. **Multi-Threaded Tests**: Verify concurrent access
2. **Exception Scenarios**: Test cleanup under errors
3. **Memory Behavior**: Monitor pool growth and reuse
4. **Database Agnostic**: Test across PostgreSQL, MySQL, SQLite

### Common Pitfalls to Avoid

1. **Global State**: Never use module variables or class variables
2. **Connection Leaks**: Always return connections to pools
3. **Race Conditions**: Synchronize pool creation properly
4. **Memory Leaks**: Ensure pools are properly cleaned up