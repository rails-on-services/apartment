# Apartment Adapters Guide

This document explains how Apartment adapters work, their implementations, and how to create custom adapters.

## Overview

Adapters are the database-specific implementation layer that handles:
- Tenant creation (schemas/databases)
- Tenant switching (changing active context)
- Tenant deletion
- Schema import and seeding

## Adapter Hierarchy

```
AbstractAdapter (lib/apartment/adapters/abstract_adapter.rb)
├── PostgresqlAdapter (PostgreSQL schemas)
├── PostgisAdapter (PostgreSQL + PostGIS extension)
├── Mysql2Adapter (MySQL databases)
├── TrilogyAdapter (MySQL via Trilogy driver)
├── Sqlite3Adapter (SQLite file-based)
├── JdbcPostgresqlAdapter (JDBC for JRuby)
└── JdbcMysqlAdapter (JDBC for JRuby)
```

## AbstractAdapter (Base Class)

### Responsibilities

1. **Tenant lifecycle management**
   - Creation with callbacks
   - Switching with automatic rollback
   - Deletion with error handling

2. **Schema management**
   - Import from `db/schema.rb`
   - Seed data execution
   - Migration running

3. **Excluded model handling**
   - Establish separate connections
   - Bypass tenant switching

### Core Methods

```ruby
class AbstractAdapter
  # Create tenant with schema import and seeding
  def create(tenant)
    run_callbacks :create do
      create_tenant(tenant)
      switch(tenant) do
        import_database_schema
        seed_data if Apartment.seed_after_create
        yield if block_given?
      end
    end
  end

  # Switch to tenant with automatic rollback
  def switch(tenant = nil)
    previous_tenant = current
    switch!(tenant)
    yield
  ensure
    switch!(previous_tenant) rescue reset
  end

  # Immediate switch (no block)
  def switch!(tenant = nil)
    run_callbacks :switch do
      connect_to_new(tenant).tap do
        Apartment.connection.clear_query_cache
      end
    end
  end

  # Drop tenant
  def drop(tenant)
    with_neutral_connection(tenant) do |conn|
      drop_command(conn, tenant)
    end
  end

  # Iterate over all tenants
  def each(tenants = Apartment.tenant_names)
    tenants.each do |tenant|
      switch(tenant) { yield tenant }
    end
  end
end
```

### Abstract Methods (Must Implement)

Subclasses must override:
- `create_tenant(tenant)` - Create schema/database
- `connect_to_new(tenant)` - Switch to tenant
- `drop_command(conn, tenant)` - Delete tenant
- `current` - Get current tenant name

## PostgreSQL Adapter

### Strategy: Schema-Based Isolation

PostgreSQL uses **schemas** (namespaces) within a single database.

### Implementation

```ruby
class PostgresqlAdapter < AbstractAdapter
  # Create new schema
  def create_tenant(tenant)
    Apartment.connection.execute(%(CREATE SCHEMA "#{tenant}"))
  rescue ActiveRecord::StatementInvalid => e
    raise TenantExists, "Schema #{tenant} already exists"
  end

  # Switch by setting search_path
  def connect_to_new(tenant = nil)
    tenant ||= default_tenant
    @current = tenant

    # Build search path: tenant, persistent_schemas, public
    path_parts = [tenant] + Array(Apartment.persistent_schemas)

    Apartment.connection.schema_search_path = path_parts.join(', ')
    Apartment.connection.execute("SET search_path TO #{path_parts.join(', ')}")
  rescue ActiveRecord::StatementInvalid
    raise TenantNotFound, "Schema #{tenant} not found"
  end

  # Drop schema
  def drop_command(conn, tenant)
    conn.execute(%(DROP SCHEMA "#{tenant}" CASCADE))
  end

  # Get current schema
  def current
    @current || default_tenant
  end
end
```

### Search Path Behavior

```sql
-- Default state
SHOW search_path;
-- Result: public

-- After switch to 'acme'
SET search_path TO "acme", public;

-- Queries now resolve to acme schema first
SELECT * FROM users;
-- Resolves to: SELECT * FROM "acme".users

-- If not found in acme, falls back to public
SELECT * FROM pg_tables;
-- Resolves to: SELECT * FROM public.pg_tables
```

### Persistent Schemas

```ruby
# config/initializers/apartment.rb
config.persistent_schemas = ['shared_extensions', 'public']

# Search path becomes: "acme", "shared_extensions", "public"
```

**Use case**: Shared extensions or utility schemas.

```sql
-- shared_extensions schema
CREATE EXTENSION IF NOT EXISTS "uuid-ossp" SCHEMA shared_extensions;

-- Available in all tenants
SELECT shared_extensions.uuid_generate_v4();
```

### Excluded Tables (pg_excluded_names)

```ruby
# config/initializers/apartment.rb
config.pg_excluded_names = /^(backup_|temp_|staging_)/

# These tables won't be created in tenant schemas
# Useful for temporary tables or backups
```

### Advantages

- ✅ **Fast switching**: Single SQL command (~0.1ms)
- ✅ **Shared connection pool**: No connection overhead
- ✅ **Heroku compatible**: Works on restricted platforms
- ✅ **Scalable**: Supports 100+ tenants easily
- ✅ **Atomic operations**: Schema-level transactions

### Disadvantages

- ❌ **PostgreSQL only**: Not portable to other databases
- ❌ **Shared connections**: Less isolation than separate databases
- ❌ **Backup complexity**: Must backup entire database (or use pg_dump per schema)
- ❌ **Search path leakage**: Bugs can access wrong schema if not careful

### Best Practices

```ruby
# Always use block-based switching
Apartment::Tenant.switch('acme') do
  # Safe: automatically rolls back on exception
  User.create!(name: 'John')
end

# Avoid manual switching
Apartment::Tenant.switch!('acme')  # Risky: no automatic rollback
User.create!(name: 'John')
Apartment::Tenant.reset
```

## MySQL Adapter

### Strategy: Database-Per-Tenant

MySQL creates separate databases for each tenant.

### Implementation

```ruby
class Mysql2Adapter < AbstractAdapter
  # Create new database
  def create_tenant(tenant)
    Apartment.connection.execute(%(CREATE DATABASE `#{tenant}`))
  rescue ActiveRecord::StatementInvalid => e
    raise TenantExists, "Database #{tenant} already exists"
  end

  # Switch by establishing new connection
  def connect_to_new(tenant = nil)
    tenant ||= default_tenant

    # Get base config and change database
    config = Apartment.connection_config.dup
    config[:database] = tenant

    # Establish new connection
    Apartment.establish_connection(config)

    @current = tenant
  rescue ActiveRecord::NoDatabaseError
    raise TenantNotFound, "Database #{tenant} not found"
  end

  # Drop database
  def drop_command(conn, tenant)
    conn.execute(%(DROP DATABASE `#{tenant}`))
  end

  # Get current database
  def current
    Apartment.connection.current_database
  end
end
```

### Connection Behavior

```ruby
# Initial state
Apartment.connection.current_database  # => "my_app_production"

# Switch to 'acme'
Apartment::Tenant.switch('acme') do
  Apartment.connection.current_database  # => "acme"

  # New connection established to acme database
  # All queries go to acme database
  User.all  # SELECT * FROM acme.users
end

# Back to original
Apartment.connection.current_database  # => "my_app_production"
```

### Advantages

- ✅ **Complete isolation**: Separate database = separate data files
- ✅ **Easy backups**: `mysqldump acme` backs up single tenant
- ✅ **Security**: Database-level permissions possible
- ✅ **Multi-server**: Different tenants can use different MySQL instances

### Disadvantages

- ❌ **Connection overhead**: New connection per switch (~10-50ms)
- ❌ **Connection limits**: MySQL has global connection limit
- ❌ **Memory usage**: Each connection pool consumes memory
- ❌ **Slower scaling**: Practical limit ~20-50 active tenants

### Multi-Server Configuration

```ruby
# config/initializers/apartment.rb
config.tenant_names = {
  'acme' => {
    adapter: 'mysql2',
    host: 'db-server-1.example.com',
    database: 'acme',
    username: 'acme_user',
    password: 'secret'
  },
  'widgets' => {
    adapter: 'mysql2',
    host: 'db-server-2.example.com',
    database: 'widgets',
    username: 'widgets_user',
    password: 'secret'
  }
}
```

### Optimization: Connection Pool Caching

```ruby
# Implement LRU cache for connection pools
# (Not in current v3, but possible enhancement)

class Mysql2Adapter < AbstractAdapter
  MAX_CACHED_POOLS = 20

  def connect_to_new(tenant)
    pool = @pool_cache.fetch(tenant) do
      # Create new pool only if not cached
      establish_pool_for(tenant)
    end

    ActiveRecord::Base.connection_handler.establish_connection(pool)
  end
end
```

## SQLite Adapter

### Strategy: File-Per-Tenant

Each tenant gets a separate SQLite file.

### Implementation

```ruby
class Sqlite3Adapter < AbstractAdapter
  # Create new database file
  def create_tenant(tenant)
    config = Apartment.connection_config.dup
    config[:database] = "db/#{tenant}.sqlite3"

    # Establish connection (creates file)
    ActiveRecord::Base.establish_connection(config)
  rescue ActiveRecord::StatementInvalid => e
    raise TenantExists, "Database #{tenant} already exists"
  end

  # Switch to different file
  def connect_to_new(tenant = nil)
    tenant ||= default_tenant

    config = Apartment.connection_config.dup
    config[:database] = "db/#{tenant}.sqlite3"

    Apartment.establish_connection(config)
    @current = tenant
  rescue ActiveRecord::NoDatabaseError
    raise TenantNotFound, "Database file for #{tenant} not found"
  end

  # Delete database file
  def drop_command(conn, tenant)
    file = "db/#{tenant}.sqlite3"
    File.delete(file) if File.exist?(file)
  end

  def current
    File.basename(Apartment.connection_config[:database], '.sqlite3')
  end
end
```

### Use Cases

- ✅ **Testing**: Each test can have isolated database file
- ✅ **Development**: Easy to inspect individual tenant data
- ✅ **Small deployments**: Single-user or embedded applications
- ❌ **Production**: Not suitable for concurrent multi-user access

### Testing Setup

```ruby
# spec/support/apartment_helper.rb
RSpec.configure do |config|
  config.before(:each) do
    # Create test tenant
    Apartment::Tenant.create('test_tenant') unless tenant_exists?('test_tenant')
    Apartment::Tenant.switch!('test_tenant')
  end

  config.after(:each) do
    # Reset to default
    Apartment::Tenant.reset
  end

  config.after(:suite) do
    # Clean up test databases
    Dir.glob('db/test_*.sqlite3').each do |file|
      File.delete(file)
    end
  end
end
```

## PostGIS Adapter

### Strategy: PostgreSQL with Spatial Extensions

Extends PostgresqlAdapter to handle PostGIS properly.

### Special Handling

```ruby
class PostgisAdapter < PostgresqlAdapter
  def create_tenant(tenant)
    super

    # Enable PostGIS in new schema
    switch(tenant) do
      Apartment.connection.execute("CREATE EXTENSION IF NOT EXISTS postgis")
      Apartment.connection.execute("CREATE EXTENSION IF NOT EXISTS postgis_topology")
    end
  end

  # Ensure spatial indexes are copied
  def import_database_schema
    super

    # Additional spatial metadata handling
    copy_spatial_reference_systems
  end
end
```

### Configuration

```ruby
# config/initializers/apartment.rb
Apartment.configure do |config|
  # Adapter auto-detected as postgis if PostGIS gem present
  config.persistent_schemas = ['postgis', 'topology']
end
```

## JDBC Adapters (JRuby)

### Purpose

Support JRuby applications using JDBC drivers.

### Implementation

```ruby
class JdbcPostgresqlAdapter < PostgresqlAdapter
  # Inherits PostgreSQL logic
  # Uses JDBC-specific connection handling
end

class JdbcMysqlAdapter < Mysql2Adapter
  # Inherits MySQL logic
  # Uses JDBC-specific connection handling
end
```

### Auto-Detection

```ruby
# lib/apartment/tenant.rb
def adapter
  Thread.current[:apartment_adapter] ||= begin
    adapter_method = "#{config[:adapter]}_adapter"

    # Detect JRuby and adjust adapter
    if defined?(JRUBY_VERSION)
      case config[:adapter]
      when /mysql/
        adapter_method = 'jdbc_mysql_adapter'
      when /postgresql/
        adapter_method = 'jdbc_postgresql_adapter'
      end
    end

    send(adapter_method, config)
  end
end
```

## Creating Custom Adapters

### Step 1: Create Adapter Class

```ruby
# lib/apartment/adapters/custom_adapter.rb
module Apartment
  module Adapters
    class CustomAdapter < AbstractAdapter
      # Required: Create tenant
      def create_tenant(tenant)
        # Database-specific creation logic
        Apartment.connection.execute("CREATE CUSTOM TENANT #{tenant}")
      end

      # Required: Switch to tenant
      def connect_to_new(tenant = nil)
        tenant ||= default_tenant
        # Database-specific switching logic
        Apartment.connection.execute("USE TENANT #{tenant}")
        @current = tenant
      end

      # Required: Drop tenant
      def drop_command(conn, tenant)
        conn.execute("DROP CUSTOM TENANT #{tenant}")
      end

      # Required: Get current tenant
      def current
        @current || default_tenant
      end

      # Optional: Custom schema import
      def import_database_schema
        # Override default behavior if needed
        super
      end
    end
  end
end
```

### Step 2: Register Adapter

```ruby
# lib/apartment/tenant.rb (monkeypatch or PR)
module Apartment
  module Tenant
    def custom_adapter(config)
      Adapters::CustomAdapter.new(config)
    end
  end
end
```

### Step 3: Configure

```ruby
# config/database.yml
production:
  adapter: custom  # Matches method name: custom_adapter
  # ... other config
```

## Adapter Selection Matrix

| Database      | Adapter               | Strategy       | Switching Speed | Scalability | Isolation |
|---------------|-----------------------|----------------|-----------------|-------------|-----------|
| PostgreSQL    | PostgresqlAdapter     | Schemas        | Very Fast       | Excellent   | Good      |
| PostGIS       | PostgisAdapter        | Schemas        | Very Fast       | Excellent   | Good      |
| MySQL         | Mysql2Adapter         | Databases      | Moderate        | Good        | Excellent |
| Trilogy       | TrilogyAdapter        | Databases      | Moderate        | Good        | Excellent |
| SQLite        | Sqlite3Adapter        | Files          | Moderate        | Poor        | Excellent |
| JRuby+PG      | JdbcPostgresqlAdapter | Schemas        | Very Fast       | Excellent   | Good      |
| JRuby+MySQL   | JdbcMysqlAdapter      | Databases      | Moderate        | Good        | Excellent |

## Performance Benchmarks

### PostgreSQL (100 tenants)

```
Tenant creation: ~50ms per tenant (schema creation + migration)
Switching: <1ms (SET search_path)
Memory: ~50MB total (shared pool)
Recommended for: 100+ tenants
```

### MySQL (20 tenants)

```
Tenant creation: ~100ms per tenant (database creation + migration)
Switching: ~10-50ms (new connection)
Memory: ~20MB per active tenant (connection pool)
Recommended for: 10-50 tenants
```

### SQLite (5 tenants)

```
Tenant creation: ~30ms per tenant (file creation + migration)
Switching: ~5-20ms (connection + file I/O)
Memory: ~5MB per database file
Recommended for: Testing, development, single-user apps
```

## Debugging Adapters

### Logging

```ruby
# Enable ActiveRecord logging
Apartment.configure do |config|
  config.active_record_log = true
end

# Check current tenant
puts "Current tenant: #{Apartment::Tenant.current}"

# Inspect adapter
adapter = Apartment::Tenant.adapter
puts "Adapter: #{adapter.class.name}"
puts "Default tenant: #{adapter.default_tenant}"
```

### PostgreSQL: Inspect Search Path

```ruby
Apartment::Tenant.switch('acme') do
  path = ActiveRecord::Base.connection.execute("SHOW search_path").first['search_path']
  puts "Search path: #{path}"
  # => "acme", "shared_extensions", "public"
end
```

### MySQL: Inspect Current Database

```ruby
Apartment::Tenant.switch('acme') do
  db = ActiveRecord::Base.connection.execute("SELECT DATABASE()").first.first
  puts "Current database: #{db}"
  # => "acme"
end
```

## Common Issues

### Issue: Tenant Not Found After Creation

**Cause**: Caching or permission issues

**Solution**:
```ruby
# Verify tenant exists
Apartment.tenant_names.include?('acme')  # Should be true

# Refresh tenant list if using callable
Apartment.reload!

# Check database
Apartment.connection.execute("SELECT schema_name FROM information_schema.schemata")
```

### Issue: Wrong Data Appearing

**Cause**: Improper tenant switching or middleware ordering

**Solution**:
```ruby
# Always use block-based switching
Apartment::Tenant.switch('acme') do
  # Safe
end

# Check middleware order
Rails.application.middleware.each { |m| puts m.inspect }
```

### Issue: Connection Pool Exhaustion (MySQL)

**Cause**: Too many simultaneous tenant connections

**Solution**:
```ruby
# Increase pool size (carefully)
# config/database.yml
production:
  pool: 25  # Default: 5

# Or implement connection pool caching/eviction
```

## References

- PostgreSQL schemas: https://www.postgresql.org/docs/current/ddl-schemas.html
- MySQL databases: https://dev.mysql.com/doc/refman/8.0/en/creating-database.html
- ActiveRecord connection handling: Rails guides
- Thread-local storage: Ruby documentation
