# CLAUDE.md - Apartment v3 Understanding Guide

**Version**: 3.x (Current Development Branch)
**Maintained by**: CampusESP
**Gem Name**: `ros-apartment`

## What This Documentation Covers

This branch contains v3 (current stable release). A v4 refactor with different architecture exists on `man/spec-restart` branch.

**Goal**: Understand v3 deeply enough to maintain it and plan v4 migration.

## Where to Start

1. **README.md** - Installation, basic usage, configuration options
2. **docs/architecture.md** - Core design decisions and WHY they were made
3. **docs/adapters.md** - Database strategy trade-offs
4. **docs/elevators.md** - Middleware design rationale
5. **lib/apartment/CLAUDE.md** - Implementation file guide
6. **spec/CLAUDE.md** - Test organization and patterns

## Core Concepts

### Multi-Tenancy via Database Isolation

**Problem**: Single application needs to serve multiple customers with data completely separated.

**v3 Solution**: Thread-local tenant switching. Each request/thread tracks which tenant it's serving.

**Key limitation**: Not fiber-safe (fibers share thread-local storage).

### Two Main Strategies

**PostgreSQL (schemas)**: Multiple namespaces in single database. Fast, scales to 100+ tenants.

**MySQL (databases)**: Separate database per tenant. Complete isolation, slower switching.

**See**: `docs/adapters.md` for trade-offs.

### Automatic Tenant Detection

**Middleware ("Elevators")**: Rack middleware extracts tenant from request (subdomain, domain, header).

**Critical**: Must position before session middleware to avoid data leakage.

**See**: `docs/elevators.md` for design decisions.

## Key Architecture Decisions

### 1. Thread-Local Adapter Storage

**Why**: Concurrent requests need isolated tenant contexts without global locks.

**Implementation**: `Thread.current[:apartment_adapter]`

**Trade-off**: Not fiber-safe, but works for 99% of Rails deployments.

**See**: `lib/apartment/tenant.rb:22-45`, `docs/architecture.md`

### 2. Block-Based Tenant Switching

**Why**: Automatic cleanup even on exceptions prevents tenant context leakage.

**Pattern**: `Apartment::Tenant.switch(tenant) { ... }` with ensure block

**Alternative rejected**: Manual switch/reset - too error-prone.

**See**: `lib/apartment/adapters/abstract_adapter.rb:86-98`

### 3. Excluded Models

**Why**: Some models (User, Company) exist globally across all tenants.

**Implementation**: Separate connections that bypass tenant switching.

**Limitation**: Can't use `has_and_belongs_to_many` - must use `has_many :through`.

**See**: `lib/apartment/adapters/abstract_adapter.rb:108-114`

### 4. Adapter Pattern

**Why**: PostgreSQL uses schemas, MySQL uses databases - fundamentally different.

**Implementation**: Abstract base class with database-specific subclasses.

**Benefit**: Unified API hides database differences.

**See**: `lib/apartment/adapters/`, `docs/adapters.md`

### 5. Callback System

**Why**: Users need logging/notification hooks without modifying gem code.

**Implementation**: ActiveSupport::Callbacks on `:create` and `:switch`.

**See**: `lib/apartment/adapters/abstract_adapter.rb:7-8`

## File Organization

**Core logic**: `lib/apartment.rb` (configuration), `lib/apartment/tenant.rb` (public API)

**Adapters**: `lib/apartment/adapters/*.rb` - Database-specific implementations

**Elevators**: `lib/apartment/elevators/*.rb` - Rack middleware for auto-switching

**Tests**: `spec/` - Adapter tests, elevator tests, integration tests

**See folder CLAUDE.md files for details on each directory.**

## Configuration Philosophy

**Dynamic tenant discovery**: `tenant_names` can be callable (proc/lambda) that queries database. Why? Tenants change at runtime.

**Fail-safe boot**: Rescue database errors during config loading. Why? App should start even if tenant table doesn't exist yet (pending migrations).

**Environment isolation**: Optional `prepend_environment`/`append_environment` to prevent cross-environment tenant name collisions.

**See**: `lib/apartment.rb:126-143` for implementation

## Common Pitfalls

**Elevator positioning**: Must be before session/auth middleware. Otherwise session data leaks across tenants.

**Not using blocks**: `switch!` without block requires manual cleanup. Easy to forget. Always prefer `switch` with block.

**HABTM with excluded models**: Doesn't work. Must use `has_many :through` instead.

**Assuming fiber safety**: v3 uses thread-local storage. Not safe for fiber-based async frameworks.

**See**: `docs/architecture.md` for detailed analysis

## Performance Characteristics

**PostgreSQL schemas**:
- Switch: <1ms
- Scalability: 100+ tenants
- Memory: Constant

**MySQL databases**:
- Switch: 10-50ms
- Scalability: 10-50 tenants
- Memory: Linear with active tenants

**See**: `docs/adapters.md` for benchmarks and trade-offs

## Testing the Gem

**Spec organization**: `spec/adapters/` for database tests, `spec/unit/elevators/` for middleware tests

**Database selection**: `DB=postgresql rspec` or `DB=mysql` or `DB=sqlite3`

**Key test pattern**: Create test tenant, switch to it, verify isolation, cleanup

**See**: `spec/CLAUDE.md` for testing patterns

## Debugging Techniques

**Check current tenant**: `Apartment::Tenant.current`

**Inspect adapter**: `Apartment::Tenant.adapter.class`

**List tenants**: `Apartment.tenant_names`

**Enable logging**: `config.active_record_log = true`

**PostgreSQL search path**: `SHOW search_path` in SQL console

**See**: Inline code comments for context-specific debugging

## Migration to v4

**v4 branch**: `man/spec-restart`

**Major changes**: Connection pool per tenant (vs thread-local switching), fiber-safe via CurrentAttributes, immutable connection descriptors

**Why v4**: Better performance (no switching overhead), true fiber safety, simpler mental model

**Migration strategy**: Understand v3 architecture first (this branch), then contrast with v4 approach

## Design Principles

**Open for extension**: Users can create custom adapters and elevators without modifying gem.

**Closed for modification**: Core logic shouldn't need changes for new use cases.

**Fail fast**: Configuration errors raise at boot. Tenant not found raises at runtime.

**Graceful degradation**: If rollback fails, fall back to default tenant rather than crash.

**See**: `docs/architecture.md` for rationale

## Getting Help

**Issues**: https://github.com/rails-on-services/apartment/issues

**Discussions**: https://github.com/rails-on-services/apartment/discussions

**Code**: Read the actual implementation files - they're well-commented

## Documentation Philosophy

**This documentation focuses on WHY, not HOW**:
- Design decisions and trade-offs
- Architecture rationale
- Pitfalls and constraints
- References to actual source files

**For HOW (implementation details)**: Read the well-commented source code in `lib/`.

**For WHAT (API reference)**: See README.md and RDoc comments.
