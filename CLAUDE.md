# CLAUDE.md - Apartment

**Gem Name**: `ros-apartment`
**Maintained by**: CampusESP
**Active work**: v4 rewrite on `man/v4-adapters` branch (phased, PR-per-sub-phase)

## Design & Plan Documents

Planning artifacts live in `docs/` with no date prefixes (git handles temporal tracking):

- `docs/designs/<feature>.md` — Design specs (what and why). Living docs, one per feature, updated in place.
- `docs/plans/<feature>/` — Implementation plans (how and in what order). Can have multiple files for phased plans.

Do NOT use `docs/superpowers/specs/` or `docs/superpowers/plans/` — those are plugin defaults that we override with the paths above.

**Key documents:**
- `docs/designs/apartment-v4.md` — v4 design spec
- `docs/plans/apartment-v4/phase-2-adapters.md` — Current phase plan (includes deferred review items)

## Where to Start

1. **README.md** - Installation, basic usage, configuration options
2. **docs/architecture.md** - Core design decisions and WHY they were made (v3)
3. **docs/designs/apartment-v4.md** - v4 architecture and motivation
4. **lib/apartment/CLAUDE.md** - Implementation file guide
5. **spec/CLAUDE.md** - Test organization and patterns

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

**See**: `Apartment::Tenant.adapter` method in `tenant.rb`, `docs/architecture.md`

### 2. Block-Based Tenant Switching

**Why**: Automatic cleanup even on exceptions prevents tenant context leakage.

**Pattern**: `Apartment::Tenant.switch(tenant) { ... }` with ensure block

**Alternative rejected**: Manual switch/reset - too error-prone.

**See**: `AbstractAdapter#switch` method in `adapters/abstract_adapter.rb`

### 3. Excluded Models

**Why**: Some models (User, Company) exist globally across all tenants.

**Implementation**: Separate connections that bypass tenant switching.

**Limitation**: Can't use `has_and_belongs_to_many` - must use `has_many :through`.

**See**: `AbstractAdapter#process_excluded_models` method in `adapters/abstract_adapter.rb`

### 4. Adapter Pattern

**Why**: PostgreSQL uses schemas, MySQL uses databases - fundamentally different.

**Implementation**: Abstract base class with database-specific subclasses.

**Benefit**: Unified API hides database differences.

**See**: `lib/apartment/adapters/`, `docs/adapters.md`

### 5. Callback System

**Why**: Users need logging/notification hooks without modifying gem code.

**Implementation**: ActiveSupport::Callbacks on `:create` and `:switch`.

**See**: Callback definitions in `AbstractAdapter` class in `adapters/abstract_adapter.rb`

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

**See**: `Apartment.extract_tenant_config` method in `lib/apartment.rb`

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

## v4 Rewrite

**Branch**: `man/v4-adapters` (phased implementation, PRs per sub-phase)

**Design spec**: `docs/designs/apartment-v4.md`

**Major changes**: Pool-per-tenant (vs thread-local switching), fiber-safe via `CurrentAttributes`, immutable connection config per pool, `Config#freeze!` after validation

**Why v4**: Eliminates thread-local tenant leakage (e.g., ActionCable shared thread pool bugs), true fiber safety, PgBouncer/RDS Proxy compatibility, simpler mental model

**Status**: Phase 1 (foundation) merged, Phase 2.1 (Tenant API, AbstractAdapter, adapter factory) in PR. See `docs/plans/apartment-v4/` for full plan.

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
