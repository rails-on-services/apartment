# CLAUDE.md - Apartment

**Gem Name**: `ros-apartment`
**Maintained by**: CampusESP
**Active work**: v4 rewrite (phased, PR-per-sub-phase off `development`)

## Design & Plan Documents

Planning artifacts live in `docs/` with no date prefixes (git handles temporal tracking):

- `docs/designs/<feature>.md` — Design specs (what and why). Living docs, one per feature, updated in place.
- `docs/plans/<feature>/` — Implementation plans (how and in what order). Can have multiple files for phased plans.

Do NOT use `docs/superpowers/specs/` or `docs/superpowers/plans/` — those are plugin defaults that we override with the paths above.

**Key documents:**
- `docs/designs/apartment-v4.md` — v4 design spec
- `docs/designs/v4-railtie-test-infra.md` — Railtie + test infrastructure design
- `docs/plans/apartment-v4/phase-2-adapters.md` — Current phase plan (includes deferred review items)

## Where to Start

1. **README.md** - Installation, basic usage, configuration options
2. **docs/architecture.md** - Core design decisions and WHY they were made (v3)
3. **docs/designs/apartment-v4.md** - v4 architecture and motivation
4. **lib/apartment/CLAUDE.md** - Implementation file guide
5. **spec/CLAUDE.md** - Test organization and patterns

## Commands

```bash
# Unit tests (no database required)
bundle exec rspec spec/unit/

# Unit tests across Rails versions
bundle exec appraisal install                              # first time only
bundle exec appraisal rails-8.1-sqlite3 rspec spec/unit/   # single version
bundle exec appraisal rspec spec/unit/                     # all versions

# v4 integration tests (requires real databases)
bundle exec appraisal rails-8.1-sqlite3 rspec spec/integration/v4/                        # SQLite
DATABASE_ENGINE=postgresql bundle exec appraisal rails-8.1-postgresql rspec spec/integration/v4/  # PostgreSQL
DATABASE_ENGINE=mysql bundle exec appraisal rails-8.1-mysql2 rspec spec/integration/v4/          # MySQL

# Lint
bundle exec rubocop

# Build gem
gem build ros-apartment.gemspec

# Coverage report (opt-in)
COVERAGE=1 bundle exec rspec spec/unit/

# Test profiling
FPROF=1 bundle exec appraisal rails-8.1-sqlite3 rspec spec/integration/v4/
EVENT_PROF=sql.active_record bundle exec appraisal rails-8.1-sqlite3 rspec spec/integration/v4/

# Request lifecycle tests (requires PostgreSQL)
DATABASE_ENGINE=postgresql bundle exec appraisal rails-8.1-postgresql rspec spec/integration/v4/request_lifecycle_spec.rb
```

**CI matrix**: Ruby 3.3/3.4/4.0 × Rails 7.2/8.0/8.1 × PG 16+18, MySQL 8.4, SQLite3. See `.github/workflows/ci.yml`.

## Core Concepts

**Multi-tenancy via database isolation**: One app, many customers, data fully separated.
- **PostgreSQL (schemas)**: Namespaces in single DB. Fast (<1ms switch), scales to 100+ tenants.
- **MySQL (databases)**: Separate DB per tenant. Complete isolation, slower switching.
- **Elevators**: Rack middleware extracts tenant from request. Must be before session middleware.
- **Excluded models**: Shared tables (User, Company) pinned to default tenant. Use `has_many :through`, not HABTM.

See `docs/architecture.md` for v3 design decisions, `docs/adapters.md` for strategy trade-offs, `docs/elevators.md` for middleware rationale.

## Key Patterns

- **Block-based switching**: Always prefer `switch(tenant) { ... }` over `switch!`. Ensure block guarantees cleanup on exceptions.
- **Adapter pattern**: Abstract base class with database-specific subclasses. Unified API hides DB differences.
- **Callbacks**: `ActiveSupport::Callbacks` on `:create` and `:switch` for logging/notification hooks.
- **Dynamic tenant discovery**: `tenants_provider` is a callable (proc/lambda) that queries the database at runtime.
- **Tenant name validation**: `TenantNameValidator` does pure in-memory format checks (no DB queries). Enforced in `AbstractAdapter#create` and `ConnectionHandling#connection_pool`. Engine-specific rules for PG identifiers, MySQL names, SQLite paths.

## Testing

```bash
bundle exec rspec spec/unit/                    # v4 unit tests (231 specs)
bundle exec appraisal rspec spec/unit/          # across all Rails versions
```

v4 unit tests are in `spec/unit/` and require no database. See `spec/CLAUDE.md` for test organization.

## v4 Rewrite

**Design spec**: `docs/designs/apartment-v4.md`

**Major changes**: Pool-per-tenant (vs thread-local switching), fiber-safe via `CurrentAttributes`, immutable connection config per pool, `Config#freeze!` after validation

**Why v4**: Fixes thread-local tenant leakage (e.g., ActionCable shared thread pool bugs). Adds fiber safety, PgBouncer/RDS Proxy transaction mode compatibility, and a simpler mental model.

**Status**: Phases 1, 2.1, 2.2, 2.3 merged. Phase 2.4 merged. Railtie + test infrastructure complete. See `docs/plans/apartment-v4/` for full plan.

## Gotchas

- **v3/v4 coexistence**: v3 files and v4 files coexist in `lib/apartment/`. Zeitwerk `loader.ignore` directives in `lib/apartment.rb` control which files load. v3 files are replaced incrementally by phase.
- **Frozen config**: `Apartment.config` is frozen after `Apartment.configure`. Tests that need different config values must call `Apartment.configure` again (not stub the frozen object).
- **Monotonic clock**: `PoolManager` uses `Process.clock_gettime(Process::CLOCK_MONOTONIC)` for timestamps, not `Time.now`. Stats return `seconds_idle` (duration), not wall-clock times.
- **schema_load_strategy**: Defaults to `nil` (no schema loading on create). Set to `:schema_rb` or `:sql` to auto-load schema into new tenants.
- **v4 Railtie**: `lib/apartment/railtie.rb` is now v4. It auto-wires `activate!`, `init`, middleware, and rake tasks after `Apartment.configure` runs. No manual middleware insertion needed.
