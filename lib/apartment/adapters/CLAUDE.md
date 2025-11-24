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

- `create_tenant(tenant)` - Create the tenant (schema/database/file)
- `connect_to_new(tenant)` - Switch to tenant (change connection or search_path)
- `drop_command(conn, tenant)` - Drop the tenant
- `current` - Get current tenant name

**See**: Abstract method definitions in `abstract_adapter.rb`.

### Common Logic Provided

**Tenant creation**: Runs callbacks, creates tenant via subclass, switches context, imports schema, optionally seeds data. See `AbstractAdapter#create` method.

**Tenant switching**: Stores previous tenant, switches, yields to block, ensures rollback in ensure clause with fallback to default. See `AbstractAdapter#switch` method.

**Schema import**: Loads `db/schema.rb` or custom schema file. See schema import logic in `abstract_adapter.rb`.

### Helper Methods

**Environmentify**: Adds Rails environment prefix/suffix to tenant name based on configuration. See `AbstractAdapter#environmentify` method.

**Excluded model processing**: Establishes separate connections for excluded models. See `AbstractAdapter#process_excluded_models` method.

## PostgreSQL Adapter

**Location**: `postgresql_adapter.rb`

### Strategy

Uses **PostgreSQL schemas** (namespaces) for tenant isolation.

### Key Implementation Details

**Create tenant**: Executes `CREATE SCHEMA` SQL command. See `PostgresqlAdapter#create_tenant` method.

**Switch tenant**: Changes `search_path` to target schema. See `PostgresqlAdapter#connect_to_new` method.

**Drop tenant**: Executes `DROP SCHEMA CASCADE`. See `PostgresqlAdapter#drop_command` method.

**Get current tenant**: Returns instance variable tracking current schema. See `PostgresqlAdapter#current` method.

### Search Path Mechanics

PostgreSQL searches schemas in order defined by `search_path`. Queries resolve to first matching table. Search path includes tenant schema, persistent schemas, then public. See search path construction in `PostgresqlAdapter#connect_to_new`.

### Persistent Schemas

Configured via `config.persistent_schemas` to specify schemas that remain in search path across all tenants.

**Use cases**:
- Shared PostgreSQL extensions (uuid-ossp, hstore, postgis)
- Utility functions/views shared across tenants
- Reference data tables

**See**: README.md for configuration examples.

### Excluded Names (pg_excluded_names)

Configured via `config.pg_excluded_names` to exclude tables/schemas from tenant cloning.

**Use cases**:
- Temporary tables
- Backup tables
- Staging/import tables

**See**: README.md for configuration patterns.

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

**Tenant creation**: Extends base PostgresqlAdapter to automatically enable PostGIS extensions in new schemas. See `PostgisAdapter#create_tenant` method.

**Schema dumping**: Custom logic to handle spatial types and indexes correctly. See `active_record/postgres/schema_dumper.rb`.

### Configuration

Typically includes PostGIS-related schemas in `persistent_schemas`. See README.md for configuration.

## MySQL Adapters

**Locations**: `mysql2_adapter.rb`, `trilogy_adapter.rb`

### Strategy

Uses **separate databases** for each tenant.

### Key Implementation Details

**Create tenant**: Executes `CREATE DATABASE` SQL command. See `Mysql2Adapter#create_tenant` method.

**Switch tenant**: Establishes new connection with different database name. See `Mysql2Adapter#connect_to_new` method.

**Drop tenant**: Executes `DROP DATABASE`. See `Mysql2Adapter#drop_command` method.

**Get current database**: Queries current database name from connection. See `Mysql2Adapter#current` method.

### Connection Management

Each tenant switch establishes new connection to different database. This creates connection pool overhead compared to PostgreSQL schemas. See `Mysql2Adapter#connect_to_new` for connection establishment.

### Multi-Server Support

MySQL adapters support hash-based configuration mapping tenant names to full connection configs, enabling different tenants on different servers. See README.md for configuration examples.

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

**Create tenant**: Creates new SQLite file and establishes connection. See `Sqlite3Adapter#create_tenant` method.

**Switch tenant**: Establishes connection to different database file. See `Sqlite3Adapter#connect_to_new` method.

**Drop tenant**: Deletes database file. See `Sqlite3Adapter#drop_command` method.

**Database file path**: Constructs file path in db/ directory. See file path construction in `Sqlite3Adapter`.

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

Inherit from standard adapters but use JDBC-specific connection handling. See `jdbc_postgresql_adapter.rb` and `jdbc_mysql_adapter.rb`.

### Auto-Detection

JRuby detection happens in `tenant.rb` - automatically selects JDBC adapters when running on JRuby. See adapter factory logic in `Apartment::Tenant.adapter_method`.

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

To support new databases: subclass `AbstractAdapter`, implement required methods (`create_tenant`, `connect_to_new`, `drop_command`, `current`), register factory method in `tenant.rb`, and configure in `database.yml`.

**See**: Existing adapters for patterns (`postgresql_adapter.rb` is most complex, `sqlite3_adapter.rb` is simplest), and `docs/adapters.md` for design rationale.

## Testing Adapters

### Adapter-Specific Tests

Each adapter has comprehensive specs covering tenant creation, switching, deletion, error handling, and callbacks. See `spec/adapters/` for test patterns.

## Debugging Adapters

### Check Current Adapter

Use `Apartment::Tenant.adapter.class.name` to inspect adapter type.

### Inspect Configuration

Access `adapter.instance_variable_get(:@config)` for configuration and `adapter.default_tenant` for default.

### Database-Specific Debugging

**PostgreSQL**: Execute `SHOW search_path` to verify current schema search path.

**MySQL**: Execute `SELECT DATABASE()` to verify current database name.

## Common Issues

### Issue: Schema/Database Not Created

**Cause**: Permissions, invalid names, or database errors

**Debug**: Wrap `Apartment::Tenant.create` in rescue block and inspect exception class and message.

### Issue: Switching Fails

**Cause**: Tenant doesn't exist or connection issues

**Debug**: Verify tenant in `Apartment.tenant_names` and check `adapter.current` state.

### Issue: Wrong Data After Switch

**Cause**: Improper cleanup or middleware ordering

**Solution**: Always use block-based switching, verify middleware order.

## Performance Optimization

### PostgreSQL: Connection Pooling

PostgreSQL adapters use shared connection pool across all tenants. Configure pool size in `database.yml`. See Rails connection pooling guides.

### MySQL: Connection Pool Caching

Consider implementing LRU cache for connection pools to limit memory usage with many tenants. Not implemented in v3 but possible via custom adapter.

## References

- PostgreSQL schemas: https://www.postgresql.org/docs/current/ddl-schemas.html
- MySQL databases: https://dev.mysql.com/doc/refman/8.0/en/creating-database.html
- ActiveRecord adapters: Rails source code
- AbstractAdapter source: `abstract_adapter.rb`
