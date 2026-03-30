# lib/apartment/adapters/ - Database Adapter Implementations

> **Note**: v4 adapters (Phase 2.2+): `abstract_adapter.rb` (base class with lifecycle, callbacks, `base_config`, `rails_env` guard), `postgresql_schema_adapter.rb`, `postgresql_database_adapter.rb`, `mysql2_adapter.rb`, `trilogy_adapter.rb`, `sqlite3_adapter.rb`. v4 adapters handle lifecycle only (create/drop/resolve_connection_config) — switching is handled by `CurrentAttributes` + pool lookup (Phase 2.3). JDBC and PostGIS adapters are dropped in v4. See `docs/designs/apartment-v4.md` for v4 architecture.

This directory contains database-specific implementations of tenant isolation strategies.

## Purpose

Adapters translate abstract tenant operations (create, switch, drop) into database-specific SQL commands and connection management.

## File Structure

```
adapters/
├── abstract_adapter.rb          # Base class with shared logic
├── postgresql_schema_adapter.rb # PostgreSQL schema-based isolation
├── postgresql_database_adapter.rb # PostgreSQL database-based isolation
├── mysql2_adapter.rb            # MySQL database-based isolation (mysql2 gem)
├── trilogy_adapter.rb           # MySQL database-based isolation (trilogy gem)
└── sqlite3_adapter.rb           # SQLite file-based isolation
```

## Adapter Hierarchy

```
AbstractAdapter
├── PostgresqlSchemaAdapter
├── PostgresqlDatabaseAdapter
├── Mysql2Adapter
│   └── TrilogyAdapter (alternative MySQL driver)
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

## PostgreSQL Adapters

### PostgresqlSchemaAdapter

**Location**: `postgresql_schema_adapter.rb`

Uses **PostgreSQL schemas** (namespaces) for tenant isolation. Does NOT environmentify tenant names — schemas are named directly. Resolves connection config via `schema_search_path`. `CREATE/DROP SCHEMA IF EXISTS ... CASCADE`.

Persistent schemas (configured via `PostgresqlConfig#persistent_schemas`) stay in `search_path` across all tenants — use for shared extensions (uuid-ossp, hstore) or reference data.

**Performance**: <1ms switching (no connection change), ~50MB total, 100+ tenants.

### PostgresqlDatabaseAdapter

**Location**: `postgresql_database_adapter.rb`

Uses **separate databases** on PostgreSQL. Environmentifies tenant names. `CREATE/DROP DATABASE IF EXISTS`.

## MySQL Adapters

**Locations**: `mysql2_adapter.rb`, `trilogy_adapter.rb`

Uses **separate databases** for each tenant. `CREATE/DROP DATABASE IF EXISTS`. Environmentifies tenant names.

`TrilogyAdapter` is an empty subclass of `Mysql2Adapter` using the `trilogy` gem. Auto-selected when `adapter: trilogy` in `database.yml`.

**Performance**: 10-50ms switching (connection establishment), ~20MB per active tenant, 10-50 concurrent tenants. Database-level isolation.

## SQLite Adapter

**Location**: `sqlite3_adapter.rb`

Uses **separate database files** for each tenant. `database` key with file path. `FileUtils.mkdir_p` for create, `FileUtils.rm_f` for drop.

Best for testing and development. Not suitable for concurrent multi-user production use. ~5MB per file, complete isolation.

## Adapter Selection Matrix

| Adapter                      | Database Type | Strategy     | Speed        | Scalability | Isolation | Best For                |
|------------------------------|---------------|--------------|--------------|-------------|-----------|-------------------------|
| PostgresqlSchemaAdapter      | PostgreSQL    | Schemas      | Very Fast    | Excellent   | Good      | 100+ tenants            |
| PostgresqlDatabaseAdapter    | PostgreSQL    | Databases    | Moderate     | Good        | Excellent | Complete PG isolation   |
| Mysql2Adapter                | MySQL         | Databases    | Moderate     | Good        | Excellent | Complete isolation      |
| TrilogyAdapter               | MySQL         | Databases    | Moderate     | Good        | Excellent | Modern MySQL client     |
| Sqlite3Adapter               | SQLite        | Files        | Moderate     | Poor        | Excellent | Testing, development    |

## Creating Custom Adapters

To support new databases: subclass `AbstractAdapter`, implement required methods (`create_tenant`, `connect_to_new`, `drop_command`, `current`), register factory method in `tenant.rb`, and configure in `database.yml`.

**See**: Existing adapters for patterns (`postgresql_schema_adapter.rb` is most complex, `sqlite3_adapter.rb` is simplest), and `docs/adapters.md` for design rationale.

## Testing Adapters

### Adapter-Specific Tests

Each adapter has specs in `spec/unit/` (unit) and `spec/integration/v4/` (integration against real databases).

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

`PostgresqlSchemaAdapter` uses a shared connection pool (schema_search_path switching). Configure pool size in `database.yml`.

### MySQL / PostgresqlDatabaseAdapter: Pool-per-Tenant

v4 uses a `PoolManager` (LRU cache with `PoolReaper`) to limit memory usage with many tenants. Idle pools are evicted automatically. See `pool_manager.rb` and `pool_reaper.rb`.

## References

- PostgreSQL schemas: https://www.postgresql.org/docs/current/ddl-schemas.html
- MySQL databases: https://dev.mysql.com/doc/refman/8.0/en/creating-database.html
- ActiveRecord adapters: Rails source code
- AbstractAdapter source: `abstract_adapter.rb`
