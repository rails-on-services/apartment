# Apartment v4 Implementation Overview

> **Spec:** [`docs/designs/apartment-v4.md`](../../designs/apartment-v4.md)

**Goal:** Ground-up rewrite of ros-apartment with immutable connection-pool-per-tenant architecture, CurrentAttributes-based tenant context, and Rails 7.2/8.0/8.1 support.

**Approach:** Fresh branch off `development`. v4 alpha branch (`man/spec-restart`) as reference. v3.3-3.4 production-hardened features ported and adapted. TDD throughout.

## Phase Map

```
Phase 1: Foundation
    |
    v
Phase 2: Adapters & Tenant API
    |
    +--------+---------+
    |        |         |
    v        v         v
Phase 3  Phase 4   Phase 5
Elevators  Railtie   Job
           & Migrations  Middleware
    |        |         |
    +--------+---------+
    |
    v
Phase 6: CLI & Generator
    |
    v
Phase 7: Integration & Stress Tests
    |
    v
Phase 8: Docs & Upgrade
```

## Phases

### Phase 1: Foundation

**Branch:** `man/v4-foundation`

**What:** The core infrastructure everything else builds on.
- `Apartment::Current` (CurrentAttributes)
- `Apartment::Config` (new configuration system)
- Exception hierarchy (`ApartmentError`, `TenantNotFound`, etc.)
- `Apartment::PoolManager` (Concurrent::Map wrapper, fetch_or_create, eviction tracking)
- `Apartment::PoolReaper` (Concurrent::TimerTask, idle eviction, LRU, graceful shutdown)
- Gemspec/version bump to 4.0.0.alpha1
- AS::Notifications instrumentation points

**Produces:** A working, tested config + pool management layer with no database dependencies. Everything is unit-testable without PostgreSQL or MySQL.

**Plan:** [`phase-1-foundation.md`](phase-1-foundation.md)

---

### Phase 2: Adapters & Tenant API

**Branch:** `man/v4-adapters`

**Depends on:** Phase 1

**What:** The database engine — adapters that create/drop/switch tenants, and the public `Apartment::Tenant` API.
- `Apartment::Adapters::AbstractAdapter` (switch, create, drop, migrate, seed, callbacks)
- `Apartment::Adapters::PostgreSQLAdapter` (schema strategy, resolve_connection_config, schema creation/dropping)
- `Apartment::Adapters::MySQL2Adapter` / `TrilogyAdapter` / `SQLite3Adapter` (database_name strategy)
- `Apartment::Tenant` module (public API: switch, switch!, current, reset, init)
- `Apartment::Patches::ConnectionHandling` (prepend on AR::Base, tenant-aware pool resolution)
- Excluded models processing

**Produces:** Working tenant switching against real databases. `Apartment::Tenant.switch("acme") { User.count }` works end-to-end.

**Requires:** PostgreSQL and MySQL in CI for adapter specs.

---

### Phase 3: Elevators

**Branch:** `man/v4-elevators`

**Depends on:** Phase 2

**What:** Rack middleware for automatic tenant detection from requests.
- `Apartment::Elevators::Generic` (base class, block-scoped switching)
- `Subdomain`, `FirstSubdomain`, `Domain`, `Host`, `HostHash` (ported from v3)
- `Header` (new — trusted header-based tenant resolution)
- `elevator_options` config support

**Produces:** Working request-level tenant switching. A Rack request with the right subdomain/header automatically sets the tenant context.

---

### Phase 4: Railtie & Migrations

**Branch:** `man/v4-railtie`

**Depends on:** Phase 2

**What:** Rails integration and migration infrastructure.
- `Apartment::Railtie` (config validation, middleware insertion, job middleware registration, AR patches, isolation_level warning)
- `Apartment::Migrator` (sequential + parallel, threads + processes opt-in, Result tracking)
- Schema dumper patch (Rails 8.1 `public.` prefix stripping, `include_schemas_in_dump`)
- Multi-database rake task enhancement (from v3.4.1)
- Rake task thin wrappers

**Produces:** `rake apartment:migrate` works. `rails s` boots with automatic tenant middleware. Parallel migrations across tenants.

---

### Phase 5: Job Middleware

**Branch:** `man/v4-jobs`

**Depends on:** Phase 2

**What:** Background job tenant propagation.
- `Apartment::Jobs::SidekiqMiddleware` (server middleware, CurrentAttributes-based)
- `Apartment::Jobs::SolidQueueHook`
- `Apartment::Jobs::ActiveJobExtension` (around_perform fallback)
- apartment-sidekiq backward compat (job format fallback)

**Produces:** Jobs enqueued in a tenant context execute in that same tenant context. Zero-config for Sidekiq 7+ and SolidQueue.

---

### Phase 6: CLI & Generator

**Branch:** `man/v4-cli`

**Depends on:** Phase 4

**What:** Developer tooling.
- `Apartment::CLI` (Thor subclass: create, drop, migrate, rollback, seed, list, current)
- `Apartment::CLI::Pool` (Thor subgroup: stats, evict)
- `bin/apartment` binstub
- `rails generate apartment:install` (initializer template with annotated defaults)

**Produces:** `apartment migrate`, `apartment pool:stats`, `rails generate apartment:install` all work.

---

### Phase 7: Integration & Stress Tests

**Branch:** `man/v4-integration-tests`

**Depends on:** Phases 1-6

**What:** Cross-cutting validation.
- Connection pool isolation spec (prove no cross-tenant leakage)
- Thread safety spec (concurrent threads, correct tenant per thread)
- Fiber safety spec (CurrentAttributes isolation across fibers)
- Request lifecycle spec (full Rack request -> tenant -> response -> cleanup)
- Pool eviction spec (idle timeout, LRU, max_total_connections)
- Memory stability spec (no pool/connection leaks under sustained load)
- Appraisals setup (Rails 7.2/8.0/8.1 x PostgreSQL/MySQL/SQLite3)
- CI workflow (GitHub Actions matrix: Ruby 3.3/3.4 x Rails x DB)

**Produces:** Confidence that the system works correctly under real-world conditions.

---

### Phase 8: Docs & Upgrade

**Branch:** `man/v4-docs`

**Depends on:** Phases 1-7

**What:** User-facing documentation and migration support.
- `docs/upgrading-to-v4.md` (checklist format, v3 -> v4 mapping)
- README.md rewrite for v4
- CLAUDE.md updates throughout `lib/` and `spec/`
- v3.5.0 deprecation bridge PR (separate branch off `development`, targets v3.x)

**Produces:** Users can upgrade from v3 to v4 with clear guidance.

## Build Order Rationale

- Phase 1 is pure Ruby — no database, no Rails, fully unit-testable. Fast to build, validates core abstractions early.
- Phase 2 is the critical path — this is where the pool-per-tenant architecture meets real databases. Most risk lives here.
- Phases 3/4/5 are independent consumers of the Phase 2 API. They can be built in parallel by different agents or sequentially.
- Phase 6 depends on Phase 4 because Thor commands delegate to the Migrator and Railtie.
- Phase 7 is deliberately last — it tests the integrated system, not individual components.
- Phase 8 can start as soon as the API stabilizes (after Phase 2) but ships last.

## Version Strategy

- Each phase merges to `man/v4` (long-lived feature branch off `development`)
- Alpha releases after Phase 2: `4.0.0.alpha1`
- Beta after Phase 5: `4.0.0.beta1`
- RC after Phase 7: `4.0.0.rc1`
- Final after Phase 8: `4.0.0`
