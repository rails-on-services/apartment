# Apartment v3 Architecture - Design Decisions

**Core files**: `lib/apartment.rb`, `lib/apartment/tenant.rb`

## Architectural Philosophy

Apartment v3 uses **thread-local state** for tenant tracking. Each thread maintains its own adapter instance, enabling concurrent request handling without cross-contamination.

**Critical design constraint**: This architecture is **not fiber-safe**. The v4 refactor addresses this limitation.

## Core Design Patterns

### 1. Adapter Pattern

**Why**: Different databases require fundamentally different isolation strategies (PostgreSQL schemas vs MySQL databases vs SQLite files).

**Implementation**: `AbstractAdapter` defines lifecycle, database-specific subclasses implement mechanics.

**Trade-off**: Adds abstraction layer but enables multi-database support.

**See**: `lib/apartment/adapters/`

### 2. Delegation Pattern

**Why**: Simplify public API while maintaining internal flexibility.

**Implementation**: `Apartment::Tenant` delegates all operations to the thread-local adapter instance.

**Benefit**: Swap adapter implementations without changing user-facing code.

**See**: `lib/apartment/tenant.rb` - uses `def_delegators`

### 3. Thread-Local Storage Pattern

**Why**: Concurrent requests need isolated tenant contexts.

**Implementation**: Adapter stored in `Thread.current[:apartment_adapter]`.

**Safe for**:
- Multi-threaded web servers (Puma, Falcon)
- Background job processors (Sidekiq with threading)
- Concurrent requests to different tenants

**Unsafe for**:
- Fiber-based async frameworks (fibers share thread storage)
- Manual thread management with shared state

**Alternative considered**: Global state with mutex locking. Rejected due to contention and complexity.

**See**: `Apartment::Tenant.adapter` method in `tenant.rb`

### 4. Callback Pattern

**Why**: Users need extension points without modifying gem code.

**Implementation**: ActiveSupport::Callbacks on `:create` and `:switch` events.

**Use cases**: Logging, notifications, analytics, APM integration.

**See**: Callback definitions in `AbstractAdapter` class

### 5. Strategy Pattern (Elevators)

**Why**: Different applications need different tenant resolution mechanisms (subdomain, domain, header, session).

**Implementation**: Pluggable Rack middleware with customizable `parse_tenant_name`.

**Benefit**: Easy to add custom strategies without changing core.

**See**: `lib/apartment/elevators/`

## Component Interaction

### Request Processing Flow

**Path**: Rack request → Elevator → Adapter → Database

**Key decision points**:
1. **Elevator positioning**: Must be before session/auth middleware. Why? Tenant context must be established before session data loads, otherwise wrong tenant's sessions leak.

2. **Automatic cleanup**: `ensure` blocks in `switch()` guarantee tenant rollback even on exceptions. Why? Prevents connection staying in wrong tenant after errors.

3. **Query cache management**: Explicitly preserve across switches. Why? Rails disables during connection establishment; must manually restore to maintain performance.

**See**: `lib/apartment/elevators/generic.rb` - base middleware pattern

### Tenant Creation Flow

**Path**: User code → Adapter → Database → Schema import → Seeding

**Key decisions**:
1. **Callback execution**: Wraps entire creation in callbacks. Why? Logging and notifications must capture the complete operation.

2. **Switch during creation**: Import and seed run in tenant context. Why? Schema loading must target new tenant, not default.

3. **Transaction handling**: Detect existing transactions (RSpec). Why? Avoid nested transactions that PostgreSQL rejects.

**See**: `AbstractAdapter#create` method

### Configuration Resolution

**Why dynamic tenant lists?**: Tenants change at runtime (new signups, deletions). Static lists become stale.

**Implementation**: `tenant_names` can be callable (proc/lambda) that queries database.

**Critical handling**: Rescue `ActiveRecord::StatementInvalid` during boot. Why? Table might not exist yet (migrations pending). Return empty array to allow app to start.

**See**: `Apartment.extract_tenant_config` method

## Data Flow Differences by Database

### PostgreSQL Schema Strategy

**Mechanism**: Single connection pool, `SET search_path` per query.

**Why this works**: PostgreSQL schemas are namespaces. Queries resolve to first matching table in search path.

**Memory efficiency**: Connection pool shared across all tenants. Only schema metadata grows with tenant count.

**Performance**: Sub-millisecond switching (simple SQL command).

**Limitation**: All tenants in same database. Backup/restore is database-wide.

### MySQL Database Strategy

**Mechanism**: Separate connection pool per tenant.

**Why different from PostgreSQL**: MySQL lacks robust schema support. Database is natural isolation unit.

**Memory cost**: Each active tenant requires connection pool (~20MB).

**Performance**: Slower switching (connection establishment overhead).

**Benefit**: Complete isolation. Can backup/restore individual tenants.

### SQLite File Strategy

**Mechanism**: Separate database file per tenant.

**Why file-based**: SQLite is single-file by design.

**Use case**: Testing and development only. Concurrent writes cause locking issues.

## Memory Management

### PostgreSQL (Shared Pool)
- Constant base: ~50MB for connection pool
- Growth: Only schema metadata (minimal)
- Scales to: 100+ tenants easily

### MySQL (Pool Per Tenant)
- Base per tenant: ~20MB connection pool
- Growth: Linear with active tenant count
- Consider: LRU cache for connection pools (not implemented in v3)

## Thread Safety Analysis

### What's Safe

**Multi-threaded request handling**: Each thread gets isolated adapter instance via `Thread.current`.

**Concurrent tenant access**: Thread 1 can be in tenant_a while Thread 2 is in tenant_b without interference.

**Background jobs**: Sidekiq workers are threads, get their own adapters.

### What's Unsafe

**Fiber switching**: Fibers within a thread share `Thread.current`. Fiber-based async (EventMachine, async gem) will have cross-contamination.

**Manual thread pooling with shared state**: Don't share adapter instances across threads.

**Solution**: v4 refactor uses `ActiveSupport::CurrentAttributes` which is fiber-safe.

## Error Handling Philosophy

### Fail Fast vs Graceful Degradation

**Tenant not found**: Raise exception. Why? Better to show error than serve wrong data.

**Tenant creation collision**: Raise exception. Why? Concurrent creation attempts indicate application bug.

**Rollback failure**: Fall back to default tenant. Why? Better to serve default data than crash entire request.

**Configuration errors**: Raise on boot. Why? Invalid config should prevent startup, not cause runtime failures.

## Excluded Models - Design Rationale

**Problem**: Some models (User, Company) exist globally, not per-tenant.

**Solution**: Establish separate connections that bypass tenant switching.

**Implementation**: PostgreSQL explicitly qualifies table names (`public.users`). MySQL uses separate connection.

**Why not conditional logic?**: Separate connections are cleaner than "if excluded, do X else do Y" throughout codebase.

**Limitation**: `has_and_belongs_to_many` doesn't work with excluded models. Must use `has_many :through` instead.

**See**: `AbstractAdapter#process_excluded_models` method

## Configuration Design

### Why Callable tenant_names?

**Problem**: Static arrays become stale as tenants are created/deleted.

**Solution**: Accept proc/lambda that queries database dynamically.

**Trade-off**: Extra query on each access. Consider caching.

### Why Hash Format for Multi-Server?

**Problem**: Different tenants might live on different database servers.

**Solution**: Hash maps tenant name to full connection config.

**Benefit**: Enables horizontal scaling and geographic distribution.

**See**: README.md examples and `Apartment.db_config_for` method

## Performance Design Decisions

### Why Query Cache Preservation?

**Impact**: 10-30% performance improvement on cache-heavy workloads.

**Cost**: Extra bookkeeping on every switch.

**Decision**: Worth it. Query cache is critical for Rails performance.

### Why Connection Verification?

**call to verify!**: Ensures connection is live after establishment.

**Why needed**: Stale connections from pool can cause mysterious failures.

**Cost**: Extra network round-trip, but prevents worse failures.

## Extension Points

### For Users

1. **Custom elevators**: Subclass `Generic`, override `parse_tenant_name`
2. **Callbacks**: Hook into `:create` and `:switch` events
3. **Custom adapters**: Subclass `AbstractAdapter` for new databases

### Design Principle

**Open for extension, closed for modification**: Users can add behavior without changing gem code.

## Limitations & Known Issues

### v3 Constraints

1. **Thread-local only**: Not fiber-safe
2. **Single adapter type**: Can't mix PostgreSQL schemas and MySQL databases in one app
3. **No horizontal sharding**: Each adapter connects to single database cluster
4. **Global excluded models**: Can't have different exclusions per tenant

### Why These Exist

Historical decisions made before newer Rails features (sharding, CurrentAttributes) existed.

### v4 Improvements

The `man/spec-restart` branch refactor addresses most limitations via connection-pool-per-tenant architecture.

## References

- Main module: `lib/apartment.rb`
- Public API: `lib/apartment/tenant.rb`
- Adapters: `lib/apartment/adapters/*.rb`
- Elevators: `lib/apartment/elevators/*.rb`
- Thread storage: Ruby documentation on `Thread.current`
- Rails connection pooling: Rails guides
