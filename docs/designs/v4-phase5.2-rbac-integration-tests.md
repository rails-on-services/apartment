# Phase 5.2: RBAC Integration Tests

## Overview

Phase 5 shipped role-aware connections, RBAC privilege grants (`app_role`), `migration_role`, schema cache, and `PendingMigrationError`. The unit test coverage is solid, but no integration tests verify that these features work against real PostgreSQL roles or MySQL users. This phase fills that gap.

**No production code changes.** This is purely additive test infrastructure and specs.

## Motivation

The Phase 5 design spec lists three integration test files that were deferred:
- `role_aware_connection_spec.rb` — PG role-based pool resolution
- `rbac_integration_spec.rb` — PG grant verification with real roles
- `migrator_rbac_spec.rb` — Migrator with `migration_role`

Without these, the RBAC system is validated only at the SQL-string level (unit tests verify the right SQL is generated). Integration tests prove the grants actually enforce the expected privilege boundary against real database engines.

## Design Decisions

### Separate connections, not SET ROLE

v4's architecture eliminates dynamic session-state mutation (`SET search_path`) in favor of pool-per-tenant with immutable connection configs. Using `SET ROLE` / `RESET ROLE` in tests would contradict this design: it mutates session state on a shared connection.

Instead, RBAC integration tests use **real LOGIN roles with separate connections**:
- Grant verification tests use `establish_connection` with different PG/MySQL usernames (same database, different credentials).
- Role-aware connection routing tests wire real `connects_to` mappings so `connected_to(role: :db_manager)` resolves to a pool with `apt_test_db_manager` credentials — the same path apartment's `ConnectionHandling` intercepts in production.

The cost is connection pool churn, but these are integration tests that already create/destroy tenants; an extra `establish_connection` per test group is negligible.

### Test role naming

PostgreSQL roles are cluster-wide (not database-scoped). Prefixed names (`apt_test_db_manager`, `apt_test_app_user`) avoid collisions with roles developers may have for other projects.

### CI provisioning + local dev fallback

Roles are created in two places:
1. **CI**: Explicit psql/mysql step in the GitHub Actions workflow. Fast, visible, runs once.
2. **Local dev**: Idempotent `before(:suite)` hook in `RbacHelper`. If role creation fails (e.g., local PG user lacks CREATEROLE), specs skip with a clear message rather than failing.

## Test Roles

### PostgreSQL

| Role | Attributes | Purpose |
|------|-----------|---------|
| `apt_test_db_manager` | `LOGIN CREATEDB` | DDL operations: create schemas, run migrations, own tables |
| `apt_test_app_user` | `LOGIN` | DML only: SELECT, INSERT, UPDATE, DELETE |

Relationship: `GRANT apt_test_app_user TO apt_test_db_manager` (so db_manager can set default privileges for app_user). `GRANT CREATE ON DATABASE ... TO apt_test_db_manager` (so db_manager can create schemas).

### MySQL

| User | Privileges | Purpose |
|------|-----------|---------|
| `apt_test_db_manager`@`%` | `ALL PRIVILEGES ON *.*` | Full DDL/DML |
| `apt_test_app_user`@`%` | `SELECT, INSERT, UPDATE, DELETE ON apartment_%.*` | DML on test databases only |

## CI Provisioning

### PostgreSQL job

The CI-created database is `apartment_postgresql_test` (via `POSTGRES_DB`), but integration tests default to `apartment_v4_test` (via `APARTMENT_TEST_PG_DB` env var fallback in `support.rb`). Roles are cluster-wide so they're created against the CI database. The `GRANT CREATE ON DATABASE` targets the test database — this runs in `RbacHelper.provision_roles!` (after `ensure_test_database!` creates it) rather than in CI, since the database may not exist at provisioning time.

```yaml
- name: Provision RBAC test roles
  if: matrix.db == 'postgresql'
  run: |
    psql -h 127.0.0.1 -U postgres -d apartment_postgresql_test <<'SQL'
      DO $$
      BEGIN
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'apt_test_db_manager') THEN
          CREATE ROLE apt_test_db_manager LOGIN CREATEDB;
        END IF;
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'apt_test_app_user') THEN
          CREATE ROLE apt_test_app_user LOGIN;
        END IF;
      END $$;
      GRANT apt_test_app_user TO apt_test_db_manager;
    SQL
```

Idempotent via `IF NOT EXISTS`. `GRANT` statements are inherently idempotent in PG. Trust auth (`POSTGRES_HOST_AUTH_METHOD: trust` already in CI) means no passwords needed. The `GRANT CREATE ON DATABASE <test_db> TO apt_test_db_manager` runs in `RbacHelper.provision_roles!` after the test database is created.

### MySQL job

CI MySQL uses `MYSQL_ALLOW_EMPTY_PASSWORD: 'yes'`, so no password flag on the client.

```yaml
- name: Provision MySQL RBAC test roles
  if: matrix.db == 'mysql'
  run: |
    mysql -h 127.0.0.1 -u root <<'SQL'
      CREATE USER IF NOT EXISTS 'apt_test_db_manager'@'%';
      CREATE USER IF NOT EXISTS 'apt_test_app_user'@'%';
      GRANT ALL PRIVILEGES ON *.* TO 'apt_test_db_manager'@'%';
      GRANT SELECT, INSERT, UPDATE, DELETE ON `apartment\_%`.* TO 'apt_test_app_user'@'%';
      FLUSH PRIVILEGES;
    SQL
```

## RbacHelper Module

`spec/integration/v4/support/rbac_helper.rb` — shared infrastructure for all RBAC spec files.

```ruby
module RbacHelper
  ROLES = {
    db_manager: 'apt_test_db_manager',
    app_user: 'apt_test_app_user'
  }.freeze
end
```

### `provision_roles!(connection)`

Idempotent role creation. Engine-aware: PG uses `CREATE ROLE`, MySQL uses `CREATE USER IF NOT EXISTS`. For PG, also runs `GRANT CREATE ON DATABASE <current_db> TO apt_test_db_manager` (deferred from CI provisioning because the test database may not exist yet at that point). Returns `true` on success, `false` on failure (triggers skip). Called in `before(:context, :rbac)` for local dev parity.

### `connect_as(role_key)`

For grant verification tests (Approach A). Calls `establish_connection` with the same database but a different username. Stashes the original config for restoration.

### `restore_default_connection!`

Restores the connection stashed by `connect_as`.

### `setup_connects_to!(base_config)`

For role-aware connection and Migrator tests (Approach B). Registers database configs for `:writing` and `:db_manager` roles with AR's `ConnectionHandler`, using the same database but different usernames. This wires real `connected_to(role:)` support so apartment's `ConnectionHandling` patch resolves the correct base config per role.

### `teardown_rbac_connections!`

Disconnects and removes non-primary pools created during tests.

## Test Files

### `role_aware_connection_spec.rb` (PostgreSQL only)

Tests that `ConnectionHandling` resolves different base configs depending on the active `connected_to` role.

**Setup**: `setup_connects_to!` wires `:writing` and `:db_manager` roles. Creates a tenant.

**Examples**:
- Separate pools created per role for the same tenant (different pool objects, different `current_user`)
- Pool keys differ by role (`"tenant:writing"` vs `"tenant:db_manager"`)
- Tenant config inherits the role's base config (db_manager username propagates through `resolve_connection_config`)

### `rbac_grants_spec.rb` (PostgreSQL only)

Tests that `app_role` grants enforce the expected privilege boundary.

**Setup**: Connect as `apt_test_db_manager`, configure `app_role: 'apt_test_app_user'`, create a tenant. This triggers `PostgresqlSchemaAdapter#grant_privileges`.

**Examples**:

As `app_user`:
- Can SELECT, INSERT, UPDATE, DELETE in the tenant schema
- Cannot CREATE TABLE in the tenant schema (`permission denied`)
- Cannot DROP SCHEMA (`permission denied`)

ALTER DEFAULT PRIVILEGES:
- As `db_manager`: create a new table in the tenant schema after initial creation
- As `app_user`: verify DML works on the new table (proves default privileges fired)

As `db_manager`:
- Can CREATE TABLE and DROP SCHEMA (retains full DDL privileges)

### `migrator_rbac_spec.rb` (PostgreSQL only)

Tests that the Migrator uses elevated credentials when `migration_role` is configured.

**Setup**: `setup_connects_to!` wires roles. Configure `migration_role: :db_manager` and `app_role`. Create tenants. Place a real migration file in a temp directory.

**Examples**:
- Migrations run as db_manager (verify table ownership via `pg_tables.tableowner`)
- `app_user` can DML on migrated tables (default privileges chain works end-to-end)
- Migration-role pools evicted after run (no `db_manager` keys remain in `pool_manager`)
- Parallel threads: each thread uses db_manager credentials (verify table ownership across all tenants with `threads: 2`)

### `mysql_rbac_grants_spec.rb` (MySQL only)

Mirrors the PG grant spec but simpler. MySQL grants on `db.*` cover future tables automatically (no `ALTER DEFAULT PRIVILEGES` equivalent needed).

**Setup**: Connect as `apt_test_db_manager`, configure `app_role: 'apt_test_app_user'`, create a tenant.

**Examples**:
- As `app_user`: can SELECT, INSERT, UPDATE, DELETE
- As `app_user`: cannot CREATE TABLE, cannot DROP DATABASE
- As `db_manager`: retains full DDL privileges

## Tagging Strategy

All specs tagged `:rbac` plus engine-specific tag (`:postgresql_only` or `:mysql_only`).

### Role provisioning hook

Uses `before(:context, :rbac)` with a module-level flag to provision once, rather than `before(:suite)` with `inclusion_filter`. The `before(:suite)` approach is fragile: it only fires when `--tag rbac` is passed explicitly, but `:rbac`-tagged examples also run when executing the full integration suite without that filter.

```ruby
RSpec.configure do |config|
  config.before(:context, :rbac) do
    next if RbacHelper.provisioned?

    unless RbacHelper.provision_roles!(ActiveRecord::Base.connection)
      skip 'RBAC test roles not available. See docs/designs/v4-phase5.2-rbac-integration-tests.md'
    end
  end
end
```

`RbacHelper.provisioned?` is a module-level boolean that prevents re-running provisioning for each describe block. On failure, `provision_roles!` returns false and all `:rbac` examples skip with a clear message.

### ConnectionHandler swap interaction

The existing `:integration` tag's `around(:each)` hook swaps `ActiveRecord::ConnectionHandler` per example and re-establishes the default connection. This discards any `connects_to` registrations made in `before(:context)`.

RBAC specs that use `setup_connects_to!` (role-aware connection and Migrator tests) must call it inside `before(:each)`, after the handler swap has created the fresh handler. This means `setup_connects_to!` runs per-example — acceptable since it's just two `establish_connection` calls (`:writing` and `:db_manager`).

Grant verification specs (`rbac_grants_spec.rb`, `mysql_rbac_grants_spec.rb`) use `connect_as` / `restore_default_connection!` which are also per-example and compatible with the handler swap.

Skip message on failure:
```
Skipped: RBAC test roles not available.
  PostgreSQL: psql -U postgres -c "CREATE ROLE apt_test_db_manager LOGIN CREATEDB; CREATE ROLE apt_test_app_user LOGIN;"
  MySQL: mysql -u root -c "CREATE USER 'apt_test_db_manager'@'%'; CREATE USER 'apt_test_app_user'@'%';"
```

## Running

```bash
# All RBAC specs (PostgreSQL)
DATABASE_ENGINE=postgresql bundle exec appraisal rails-8.1-postgresql \
  rspec spec/integration/v4/ --tag rbac

# Just grant verification (PostgreSQL)
DATABASE_ENGINE=postgresql bundle exec appraisal rails-8.1-postgresql \
  rspec spec/integration/v4/rbac_grants_spec.rb

# MySQL grants
DATABASE_ENGINE=mysql bundle exec appraisal rails-8.1-mysql2 \
  rspec spec/integration/v4/mysql_rbac_grants_spec.rb
```

## Files

```
.github/workflows/ci.yml                          # MODIFY — add RBAC role provisioning steps

spec/integration/v4/
  support/
    rbac_helper.rb                                 # NEW — role provisioning, connect_as, setup_connects_to!
  role_aware_connection_spec.rb                    # NEW — :rbac, :postgresql_only
  rbac_grants_spec.rb                             # NEW — :rbac, :postgresql_only
  migrator_rbac_spec.rb                           # NEW — :rbac, :postgresql_only
  mysql_rbac_grants_spec.rb                       # NEW — :rbac, :mysql_only
```

## Out of Scope

- Thor CLI commands (Phase 6)
- SQLite RBAC (SQLite has no role system)
- Per-tenant schema cache integration tests (unit coverage sufficient; Phase 5 spec listed these but the dump/load API is straightforward file IO)
- `PendingMigrationError` integration test (Phase 5 spec listed a SQLite test; deferred because the check is a single `needs_migration?` call gated by config/env/Current flags, all of which have unit coverage. If it breaks in integration, the symptom is obvious: dev server raises on first request.)
- `prevent_writes: true` propagation to tenant pools (this is an AR `connected_to` option handled by Rails' `ConnectionHandler`, not by apartment's `ConnectionHandling` patch; apartment passes the role through, AR enforces write protection)
- Stress testing RBAC under concurrent load (Phase 7)
- `PostgresqlDatabaseAdapter` RBAC grants (the adapter inherits no-op from `AbstractAdapter`; the design spec recommends the callable escape hatch for database-per-tenant RBAC)
