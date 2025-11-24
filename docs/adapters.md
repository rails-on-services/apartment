# Apartment Adapters - Design & Architecture

**Key files**: `lib/apartment/adapters/*.rb`

## Purpose

Adapters translate abstract tenant operations into database-specific implementations. Each database has fundamentally different isolation mechanisms, requiring separate strategies.

## Design Decision: Why Adapter Pattern?

**Problem**: PostgreSQL uses schemas, MySQL uses databases, SQLite uses files. A unified API across these different approaches requires abstraction.

**Solution**: Adapter pattern with shared base class defining lifecycle, database-specific subclasses implementing mechanics.

**Trade-off**: Adds complexity but enables multi-database support without polluting core logic.

## Adapter Hierarchy

See `lib/apartment/adapters/` for implementations:
- `abstract_adapter.rb` - Shared lifecycle, callbacks, error handling
- `postgresql_adapter.rb` - Schema-based isolation (3 variants)
- `mysql2_adapter.rb` - Database-per-tenant
- `sqlite3_adapter.rb` - File-per-tenant
- JDBC variants for JRuby

## AbstractAdapter - Design Rationale

**File**: `lib/apartment/adapters/abstract_adapter.rb`

### Why Callbacks?

Provides extension points for logging, notifications, analytics without modifying core adapter code. Users can hook into `:create` and `:switch` events.

### Why Ensure Blocks in switch()?

**Critical decision**: Always rollback to previous tenant, even if block raises. Prevents tenant context leakage across requests/jobs. If rollback fails, fall back to default tenant as last resort.

**Alternative considered**: Let exceptions propagate without cleanup. Rejected because it leaves connections in wrong tenant state.

### Why Query Cache Management?

Rails disables query cache during connection establishment. Must explicitly preserve and restore state across tenant switches to maintain performance.

### Why Separate Connection Handler?

`SeparateDbConnectionHandler` prevents admin operations (CREATE/DROP DATABASE) from polluting the main application connection pool. Multi-server setups especially need this isolation.

## PostgreSQL Adapters - Three Strategies

**Files**: `postgresql_adapter.rb` (3 classes in one file)

### 1. PostgresqlAdapter (Database-per-tenant)

Rarely used. Most deployments use schemas instead.

### 2. PostgresqlSchemaAdapter (Schema-based - Primary)

**Why schemas?**: Single database, multiple namespaces. Fast switching via `SET search_path`. Scales to hundreds of tenants without connection overhead.

**Key design decisions**:
- **Search path ordering**: Tenant schema first, then persistent schemas, then public. Tables resolve in order.
- **Persistent schemas**: Shared extensions (PostGIS, uuid-ossp) remain accessible across all tenants.
- **Excluded model handling**: Explicitly qualify table names with default schema to prevent tenant-based queries.

**Trade-off**: Less isolation than separate databases, but massively better performance and scalability.

### 3. PostgresqlSchemaFromSqlAdapter (pg_dump-based)

**Why pg_dump instead of schema.rb?**:
- Handles PostgreSQL-specific features (extensions, custom types, constraints) that Rails schema dumper misses
- Required for PostGIS spatial types
- Necessary for complex production schemas

**Why patch search_path in dump?**: pg_dump outputs assume specific search_path. Must rewrite SQL to target new tenant schema instead of source schema.

**Why environment variable handling?**: pg_dump shell command reads PGHOST/PGUSER/etc from ENV. Must temporarily set, execute, then restore to avoid polluting global state.

**Alternative considered**: Use Rails schema.rb. Rejected because it loses PostgreSQL-specific features.

## MySQL Adapters - Database Isolation

**Files**: `mysql2_adapter.rb`, `trilogy_adapter.rb`

### Why Separate Databases?

MySQL doesn't have PostgreSQL's robust schema support. Database-level isolation is the natural fit.

**Implications**:
- Each switch establishes new connection to different database
- Connection pool per tenant (memory overhead)
- Practical limit of 10-50 concurrent tenants before connection exhaustion

### Why Trilogy Adapter?

Modern MySQL driver. Identical implementation to Mysql2Adapter, just different gem.

### Multi-Server Support

Hash-based tenant config allows different tenants on different MySQL servers. Enables horizontal scaling and geographic distribution.

## SQLite Adapter - File-Based

**File**: `sqlite3_adapter.rb`

### Why File-Per-Tenant?

SQLite is single-file database. Natural isolation is separate files.

**Use case**: Testing, development, single-user apps. **Not** production multi-tenant.

## Performance Characteristics

**PostgreSQL schemas**:
- Switch latency: <1ms (SQL command)
- Scalability: 100+ tenants easily
- Memory: Constant (~50MB)

**MySQL databases**:
- Switch latency: 10-50ms (connection establishment)
- Scalability: 10-50 tenants
- Memory: ~20MB per active tenant

**SQLite files**:
- Switch latency: 5-20ms (file I/O)
- Scalability: Not recommended for concurrent users
- Memory: ~5MB per database

## Adapter Selection Matrix

| Database   | Strategy     | Speed     | Scalability | Isolation | Best For              |
|------------|--------------|-----------|-------------|-----------|-----------------------|
| PostgreSQL | Schemas      | Very Fast | Excellent   | Good      | 100+ tenants          |
| MySQL      | Databases    | Moderate  | Good        | Excellent | Complete isolation    |
| SQLite     | Files        | Moderate  | Poor        | Excellent | Testing only          |

## Extension Points

### Creating Custom Adapters

**Why you might need this**: Supporting databases not yet implemented (Oracle, SQL Server, CockroachDB).

**What to implement**:
1. Subclass `AbstractAdapter`
2. Define required methods: `create_tenant`, `connect_to_new`, `drop_command`, `current`
3. Register factory method in `lib/apartment/tenant.rb`

**See**: Existing adapters for patterns. PostgreSQL is most complex, SQLite is simplest.

## Common Pitfalls & Design Constraints

### Why Transaction Handling in create_tenant?

RSpec tests run in transactions. Must detect open transactions and avoid nested BEGIN/COMMIT to prevent errors.

### Why Separate rescue_from per Adapter?

Different databases raise different exceptions. PostgreSQL raises `PG::Error`, MySQL raises different errors. Each adapter specifies what to rescue.

### Why environmentify()?

Prevents tenant name collisions across Rails environments. `development_acme` vs `production_acme`. Optional but recommended for shared infrastructure.

## Thread Safety

**Critical**: Adapters stored in `Thread.current[:apartment_adapter]`. Each thread gets isolated adapter instance.

**Implication**: Safe for multi-threaded servers (Puma), background jobs (Sidekiq).

**Limitation**: Not fiber-safe. v4 refactor addresses this.

## References

- AbstractAdapter implementation: `lib/apartment/adapters/abstract_adapter.rb`
- PostgreSQL variants: `lib/apartment/adapters/postgresql_adapter.rb`
- MySQL variants: `lib/apartment/adapters/mysql2_adapter.rb`, `trilogy_adapter.rb`
- SQLite: `lib/apartment/adapters/sqlite3_adapter.rb`
- PostgreSQL documentation: https://www.postgresql.org/docs/current/ddl-schemas.html
