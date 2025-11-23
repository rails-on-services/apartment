# lib/apartment/adapters/ - Database Adapter Implementations

This directory contains database-specific implementations of tenant isolation strategies.

## Purpose

Adapters translate abstract tenant operations (create, switch, drop) into database-specific SQL commands and connection management.

## File Structure

```
adapters/
├── abstract_adapter.rb          # Base class with shared logic
├── postgresql_adapter.rb         # PostgreSQL schema-based isolation
├── postgis_adapter.rb           # PostgreSQL with PostGIS extensions
├── mysql2_adapter.rb            # MySQL database-based isolation (mysql2 gem)
├── trilogy_adapter.rb           # MySQL database-based isolation (trilogy gem)
├── sqlite3_adapter.rb           # SQLite file-based isolation
├── abstract_jdbc_adapter.rb     # Base for JDBC adapters (JRuby)
├── jdbc_postgresql_adapter.rb   # JDBC PostgreSQL adapter
└── jdbc_mysql_adapter.rb        # JDBC MySQL adapter
```

## Adapter Hierarchy

```
AbstractAdapter
├── PostgresqlAdapter
│   ├── PostgisAdapter (PostgreSQL + spatial extensions)
│   └── JdbcPostgresqlAdapter (JDBC for JRuby)
├── Mysql2Adapter
│   ├── TrilogyAdapter (alternative MySQL driver)
│   └── JdbcMysqlAdapter (JDBC for JRuby)
└── Sqlite3Adapter
```

## AbstractAdapter - Base Implementation

**Location**: `abstract_adapter.rb`

### Responsibilities

1. **Common tenant lifecycle logic**:
   - Callback execution (`:create`, `:switch`)
   - Schema import coordination
   - Seed data execution
   - Exception handling

2. **Excluded model management**:
   - Establish separate connections for excluded models
   - Ensure they bypass tenant switching

3. **Helper methods**:
   - `environmentify(tenant)` - Add Rails env to tenant name
   - `seed_data` - Load seeds.rb in tenant context
   - `each(tenants)` - Iterate over tenants

### Abstract Methods (Subclasses Must Implement)

```ruby
# Create the tenant (schema/database/file)
def create_tenant(tenant)
  raise NotImplementedError
end

# Switch to tenant (change connection or search_path)
def connect_to_new(tenant = nil)
  raise NotImplementedError
end

# Drop the tenant
def drop_command(conn, tenant)
  raise NotImplementedError
end

# Get current tenant name
def current
  raise NotImplementedError
end
```

### Common Logic Provided

**Tenant creation with callbacks**:
```ruby
def create(tenant)
  run_callbacks :create do
    create_tenant(tenant)              # Subclass implements
    switch(tenant) do
      import_database_schema           # Loads db/schema.rb
      seed_data if Apartment.seed_after_create  # Loads db/seeds.rb
      yield if block_given?
    end
  end
end
```

**Tenant switching with automatic rollback**:
```ruby
def switch(tenant = nil)
  previous_tenant = current
  switch!(tenant)                      # Subclass implements
  yield
ensure
  begin
    switch!(previous_tenant)
  rescue StandardError
    reset                               # Fallback to default
  end
end
```

**Schema import**:
```ruby
def import_database_schema
  silence_warnings do
    load_or_raise(Apartment.database_schema_file)
  end
end
```

### Helper Methods

**Environmentify**: Add Rails environment to tenant name
```ruby
# config.prepend_environment = true
environmentify('acme')  # => 'development_acme' (in development)
                        # => 'acme' (in production)

# config.append_environment = true
environmentify('acme')  # => 'acme_development' (in development)
```

**Excluded model processing**:
```ruby
def process_excluded_models
  Apartment.excluded_models.each do |model_name|
    model = model_name.constantize
    model.establish_connection(@config)
  end
end
```

## PostgreSQL Adapter

**Location**: `postgresql_adapter.rb`

### Strategy

Uses **PostgreSQL schemas** (namespaces) for tenant isolation.

### Key Implementation Details

**Create tenant** (creates schema):
```ruby
def create_tenant(tenant)
  Apartment.connection.execute(%(CREATE SCHEMA "#{tenant}"))
rescue ActiveRecord::StatementInvalid => e
  raise TenantExists, "Schema #{tenant} already exists"
end
```

**Switch tenant** (changes search_path):
```ruby
def connect_to_new(tenant = nil)
  tenant ||= default_tenant
  @current = tenant

  # Build search path: tenant, persistent_schemas, public
  path_parts = [tenant] + Array(Apartment.persistent_schemas)
  path = path_parts.map { |s| %("#{s}") }.join(', ')

  # Set search path for all queries
  Apartment.connection.schema_search_path = path
  Apartment.connection.execute("SET search_path TO #{path}")
rescue ActiveRecord::StatementInvalid
  raise TenantNotFound, "Schema #{tenant} not found"
end
```

**Drop tenant** (drops schema):
```ruby
def drop_command(conn, tenant)
  conn.execute(%(DROP SCHEMA "#{tenant}" CASCADE))
end
```

**Get current tenant**:
```ruby
def current
  @current || default_tenant
end
```

### Search Path Mechanics

When you execute a query, PostgreSQL searches schemas in order:

```sql
-- Search path: "acme", "shared_extensions", "public"
SELECT * FROM users;

-- PostgreSQL searches:
-- 1. acme.users (if exists) ← FOUND
-- 2. shared_extensions.users (if acme.users doesn't exist)
-- 3. public.users (if neither exists)
```

### Persistent Schemas

Configured via `config.persistent_schemas`:

```ruby
# config/initializers/apartment.rb
config.persistent_schemas = ['shared_extensions', 'public']
```

**Use cases**:
- Shared PostgreSQL extensions (uuid-ossp, hstore, postgis)
- Utility functions/views shared across tenants
- Reference data tables

**Example**:
```sql
-- shared_extensions schema
CREATE EXTENSION IF NOT EXISTS "uuid-ossp" SCHEMA shared_extensions;

-- Available in all tenants
Apartment::Tenant.switch('acme') do
  # Can use extension even though in acme schema
  User.create!(id: 'SELECT shared_extensions.uuid_generate_v4()')
end
```

### Excluded Names (pg_excluded_names)

Configured via `config.pg_excluded_names`:

```ruby
# config/initializers/apartment.rb
config.pg_excluded_names = /^(backup_|temp_|staging_)/

# These tables won't be cloned to tenant schemas
```

**Use cases**:
- Temporary tables
- Backup tables
- Staging/import tables

### Performance Characteristics

- **Switching**: <1ms (SQL command)
- **Memory**: ~50MB total (shared connection pool)
- **Scalability**: 100+ tenants easily
- **Isolation**: Schema-level (good, not absolute)

## PostGIS Adapter

**Location**: `postgis_adapter.rb`

### Strategy

Extends `PostgresqlAdapter` with PostGIS spatial extension support.

### Key Differences

**Tenant creation with extension**:
```ruby
def create_tenant(tenant)
  super  # Create schema

  switch(tenant) do
    # Enable PostGIS in new schema
    Apartment.connection.execute("CREATE EXTENSION IF NOT EXISTS postgis")
    Apartment.connection.execute("CREATE EXTENSION IF NOT EXISTS postgis_topology")
  end
end
```

**Schema dumping**:
Custom logic to handle spatial types and indexes correctly.

### Configuration

```ruby
# config/initializers/apartment.rb
config.persistent_schemas = ['postgis', 'topology', 'public']
```

## MySQL Adapters

**Locations**: `mysql2_adapter.rb`, `trilogy_adapter.rb`

### Strategy

Uses **separate databases** for each tenant.

### Key Implementation Details

**Create tenant** (creates database):
```ruby
def create_tenant(tenant)
  Apartment.connection.execute(%(CREATE DATABASE `#{tenant}`))
rescue ActiveRecord::StatementInvalid => e
  raise TenantExists, "Database #{tenant} already exists"
end
```

**Switch tenant** (establishes new connection):
```ruby
def connect_to_new(tenant = nil)
  tenant ||= default_tenant

  # Clone base config and change database
  config = Apartment.connection_config.dup
  config[:database] = tenant

  # Establish new connection
  Apartment.establish_connection(config)

  @current = tenant
rescue ActiveRecord::NoDatabaseError
  raise TenantNotFound, "Database #{tenant} not found"
end
```

**Drop tenant** (drops database):
```ruby
def drop_command(conn, tenant)
  conn.execute(%(DROP DATABASE `#{tenant}`))
end
```

**Get current database**:
```ruby
def current
  Apartment.connection.current_database
end
```

### Connection Management

Each tenant switch establishes a **new connection** to a different database:

```ruby
# Initial state
Apartment.connection.current_database  # => "app_production"

# Switch creates new connection
Apartment::Tenant.switch('acme') do
  Apartment.connection.current_database  # => "acme"
  # New connection to `acme` database
end

# Switches back
Apartment.connection.current_database  # => "app_production"
```

### Multi-Server Support

MySQL adapters support **different database servers per tenant**:

```ruby
# config/initializers/apartment.rb
config.tenant_names = {
  'acme' => {
    adapter: 'mysql2',
    host: 'db-server-1.example.com',
    database: 'acme',
    username: 'user1',
    password: 'secret1'
  },
  'widgets' => {
    adapter: 'mysql2',
    host: 'db-server-2.example.com',
    database: 'widgets',
    username: 'user2',
    password: 'secret2'
  }
}
```

### Performance Characteristics

- **Switching**: 10-50ms (connection establishment)
- **Memory**: ~20MB per active tenant (connection pool)
- **Scalability**: 10-50 concurrent tenants
- **Isolation**: Database-level (excellent)

### Trilogy Adapter

**Location**: `trilogy_adapter.rb`

Identical to `Mysql2Adapter` but uses the `trilogy` gem (modern MySQL client).

**Usage**: Auto-selected if `adapter: trilogy` in `database.yml`.

## SQLite Adapter

**Location**: `sqlite3_adapter.rb`

### Strategy

Uses **separate database files** for each tenant.

### Key Implementation Details

**Create tenant** (creates file):
```ruby
def create_tenant(tenant)
  config = Apartment.connection_config.dup
  config[:database] = database_file_for(tenant)  # e.g., "db/acme.sqlite3"

  # Establish connection (creates file)
  ActiveRecord::Base.establish_connection(config)
rescue ActiveRecord::StatementInvalid => e
  raise TenantExists, "Database #{tenant} already exists"
end
```

**Switch tenant** (connects to different file):
```ruby
def connect_to_new(tenant = nil)
  tenant ||= default_tenant

  config = Apartment.connection_config.dup
  config[:database] = database_file_for(tenant)

  Apartment.establish_connection(config)
  @current = tenant
rescue ActiveRecord::NoDatabaseError
  raise TenantNotFound, "Database file for #{tenant} not found"
end
```

**Drop tenant** (deletes file):
```ruby
def drop_command(conn, tenant)
  file = database_file_for(tenant)
  File.delete(file) if File.exist?(file)
end
```

**Database file path**:
```ruby
def database_file_for(tenant)
  "db/#{tenant}.sqlite3"
end
```

### Use Cases

- ✅ **Testing**: Each test tenant is isolated file
- ✅ **Development**: Easy to inspect individual tenant data
- ✅ **Single-user apps**: Desktop or embedded applications
- ❌ **Production**: Not suitable for concurrent multi-user access

### Performance Characteristics

- **Switching**: 5-20ms (file I/O + connection)
- **Memory**: ~5MB per database file
- **Scalability**: Not recommended for production multi-tenant
- **Isolation**: Complete (separate files)

## JDBC Adapters (JRuby)

**Locations**: `abstract_jdbc_adapter.rb`, `jdbc_postgresql_adapter.rb`, `jdbc_mysql_adapter.rb`

### Purpose

Support JRuby deployments using JDBC drivers.

### Implementation

Inherit from standard adapters but use JDBC-specific connection handling:

```ruby
class JdbcPostgresqlAdapter < PostgresqlAdapter
  # Uses JDBC connection methods
  # Otherwise identical to PostgresqlAdapter
end

class JdbcMysqlAdapter < Mysql2Adapter
  # Uses JDBC connection methods
  # Otherwise identical to Mysql2Adapter
end
```

### Auto-Detection

In `lib/apartment/tenant.rb`:

```ruby
def adapter
  adapter_method = "#{config[:adapter]}_adapter"

  # Detect JRuby and adjust
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
```

## Adapter Selection Matrix

| Adapter                | Database Type | Strategy     | Speed        | Scalability | Isolation | Best For                |
|------------------------|---------------|--------------|--------------|-------------|-----------|-------------------------|
| PostgresqlAdapter      | PostgreSQL    | Schemas      | Very Fast    | Excellent   | Good      | 100+ tenants            |
| PostgisAdapter         | PostGIS       | Schemas      | Very Fast    | Excellent   | Good      | Spatial data apps       |
| Mysql2Adapter          | MySQL         | Databases    | Moderate     | Good        | Excellent | Complete isolation      |
| TrilogyAdapter         | MySQL         | Databases    | Moderate     | Good        | Excellent | Modern MySQL client     |
| Sqlite3Adapter         | SQLite        | Files        | Moderate     | Poor        | Excellent | Testing, development    |
| JdbcPostgresqlAdapter  | PostgreSQL    | Schemas      | Very Fast    | Excellent   | Good      | JRuby deployments       |
| JdbcMysqlAdapter       | MySQL         | Databases    | Moderate     | Good        | Excellent | JRuby deployments       |

## Creating Custom Adapters

### Step 1: Create Adapter Class

```ruby
# lib/apartment/adapters/custom_adapter.rb
module Apartment
  module Adapters
    class CustomAdapter < AbstractAdapter
      # Implement required methods
      def create_tenant(tenant)
        # Database-specific creation
      end

      def connect_to_new(tenant = nil)
        # Database-specific switching
      end

      def drop_command(conn, tenant)
        # Database-specific deletion
      end

      def current
        # Return current tenant name
      end
    end
  end
end
```

### Step 2: Register Adapter

```ruby
# lib/apartment/tenant.rb (add method)
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
  adapter: custom  # Matches method name
  # ... other config
```

## Testing Adapters

### Adapter-Specific Tests

```ruby
# spec/apartment/adapters/postgresql_adapter_spec.rb
RSpec.describe Apartment::Adapters::PostgresqlAdapter do
  let(:config) { Apartment.connection_config }
  let(:adapter) { described_class.new(config) }

  describe '#create_tenant' do
    it 'creates a schema' do
      adapter.create('test_tenant')

      schemas = ActiveRecord::Base.connection.execute(
        "SELECT schema_name FROM information_schema.schemata WHERE schema_name = 'test_tenant'"
      )
      expect(schemas.count).to eq(1)
    end
  end

  describe '#switch' do
    it 'changes search_path' do
      adapter.create('test_tenant')
      adapter.switch!('test_tenant')

      path = ActiveRecord::Base.connection.execute("SHOW search_path").first['search_path']
      expect(path).to include('test_tenant')
    end
  end
end
```

## Debugging Adapters

### Check Current Adapter

```ruby
adapter = Apartment::Tenant.adapter
puts "Adapter class: #{adapter.class.name}"
# => "Apartment::Adapters::PostgresqlAdapter"
```

### Inspect Configuration

```ruby
puts "Config: #{adapter.instance_variable_get(:@config).inspect}"
puts "Default tenant: #{adapter.default_tenant}"
```

### Database-Specific Debugging

**PostgreSQL - Check search path**:
```ruby
Apartment::Tenant.switch('acme') do
  path = ActiveRecord::Base.connection.execute("SHOW search_path").first['search_path']
  puts "Search path: #{path}"
end
```

**MySQL - Check current database**:
```ruby
Apartment::Tenant.switch('acme') do
  db = ActiveRecord::Base.connection.execute("SELECT DATABASE()").first.first
  puts "Current DB: #{db}"
end
```

## Common Issues

### Issue: Schema/Database Not Created

**Cause**: Permissions, invalid names, or database errors

**Debug**:
```ruby
begin
  Apartment::Tenant.create('test')
rescue => e
  puts "Error: #{e.class} - #{e.message}"
  puts e.backtrace.first(5)
end
```

### Issue: Switching Fails

**Cause**: Tenant doesn't exist or connection issues

**Debug**:
```ruby
# Verify tenant exists
puts Apartment.tenant_names.inspect

# Check adapter state
adapter = Apartment::Tenant.adapter
puts "Current: #{adapter.current rescue 'ERROR'}"
```

### Issue: Wrong Data After Switch

**Cause**: Improper cleanup or middleware ordering

**Solution**: Always use block-based switching, verify middleware order.

## Performance Optimization

### PostgreSQL: Connection Pooling

PostgreSQL adapters use a **shared connection pool**, so scaling is excellent:

```yaml
# config/database.yml
production:
  pool: 25  # Shared across all tenants
```

### MySQL: Connection Pool Caching

Implement LRU cache for connection pools (not in v3, but possible):

```ruby
# Pseudo-code for optimization
class CachedMysql2Adapter < Mysql2Adapter
  def connect_to_new(tenant)
    @pool_cache ||= LRUCache.new(max_size: 20)

    pool = @pool_cache.fetch(tenant) do
      establish_pool_for(tenant)
    end

    switch_to_pool(pool)
  end
end
```

## References

- PostgreSQL schemas: https://www.postgresql.org/docs/current/ddl-schemas.html
- MySQL databases: https://dev.mysql.com/doc/refman/8.0/en/creating-database.html
- ActiveRecord adapters: Rails source code
- AbstractAdapter source: `abstract_adapter.rb`
