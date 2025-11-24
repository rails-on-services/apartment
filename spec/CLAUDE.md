# spec/ - Apartment Test Suite

This directory contains the test suite for Apartment v3, covering adapters, elevators, configuration, and integration scenarios.

## Directory Structure

```
spec/
├── adapters/              # Database adapter specs (PostgreSQL, MySQL, SQLite)
├── apartment/             # Core module specs
├── config/                # Database configuration for tests
├── dummy/                 # Rails dummy app for integration testing
├── dummy_engine/          # Rails engine for testing engine integration
├── examples/              # Shared example groups for adapter testing
├── integration/           # Full-stack integration tests
├── schemas/               # Test schema fixtures
├── shared_examples/       # Reusable RSpec shared examples
├── support/               # Test helpers and configuration
├── tasks/                 # Rake task specs
├── unit/                  # Unit tests (elevators, migrator, config)
├── apartment_spec.rb      # Main Apartment module specs
├── spec_helper.rb         # RSpec configuration
└── tenant_spec.rb         # Apartment::Tenant public API specs
```

## Test Organization

### Adapter Tests (spec/adapters/)

**Purpose**: Test database-specific tenant operations

**Files**:
- `postgresql_adapter_spec.rb` - PostgreSQL schema isolation
- `mysql2_adapter_spec.rb` - MySQL database isolation
- `sqlite3_adapter_spec.rb` - SQLite file isolation
- `trilogy_adapter_spec.rb` - Trilogy MySQL driver
- `abstract_adapter_spec.rb` - Shared adapter behavior

**What's tested**:
- Tenant creation/deletion
- Schema import and seeding
- Tenant switching
- Error handling (TenantExists, TenantNotFound)
- Excluded model behavior
- Callbacks

**See**: `spec/adapters/` for test implementations.

### Elevator Tests (spec/unit/elevators/)

**Purpose**: Test Rack middleware tenant detection

**Files**:
- `generic_spec.rb` - Base elevator with Proc
- `subdomain_spec.rb` - Subdomain-based switching
- `first_subdomain_spec.rb` - First subdomain extraction
- `domain_spec.rb` - Domain-based switching
- `host_spec.rb` - Full hostname switching
- `host_hash_spec.rb` - Hash-based tenant mapping

**What's tested**:
- Tenant name parsing from requests
- Exclusion logic
- Middleware integration
- Error handling

**See**: `spec/unit/elevators/` for test implementations.

### Integration Tests (spec/integration/)

**Purpose**: Full-stack scenarios with real database operations

**What's tested**:
- Complete request → response flows
- Middleware + adapter interaction
- Multi-tenant data isolation
- Concurrent tenant access
- Migration scenarios

**See**: `spec/integration/` for test implementations.

### Dummy App (spec/dummy/)

**Purpose**: Minimal Rails app for integration testing

**Contents**:
- Rails application structure
- Models: User, Company (excluded model)
- Migrations
- Seeds
- Configuration

**Usage**: Tests run within this Rails context to verify real-world behavior.

## Test Configuration

### spec_helper.rb

**Responsibilities**:
- RSpec configuration
- Database setup/teardown
- Test database selection (PostgreSQL, MySQL, SQLite)
- Shared helper loading
- Apartment configuration for tests

**See**: `spec/spec_helper.rb` for complete configuration.

### Database Configuration (spec/config/)

**Files**:
- `database.yml` - Multi-database configuration
- Environment-specific configs

**Databases supported**:
- PostgreSQL (default)
- MySQL
- SQLite

**Selection**: Via `DB` environment variable (`DB=postgresql`, `DB=mysql`, `DB=sqlite3`)

## Shared Examples (spec/examples/)

**Why shared examples?**: Apartment promises a unified API regardless of database. Without shared examples, behavior could diverge between PostgreSQL and MySQL implementations.

**How they enforce contracts**: Each adapter must pass identical tests. If PostgreSQL adapter can create/switch/drop tenants, MySQL adapter must too. Prevents "works on PostgreSQL but breaks on MySQL" scenarios.

**Files**:
- `adapter_examples.rb` - Common adapter behavior
- `schema_examples.rb` - Schema import/export
- `seed_examples.rb` - Seed data handling

**Trade-off**: More test code to maintain, but ensures cross-database compatibility.

**See**: `spec/examples/` for shared example implementations.

## Support Files (spec/support/)

Test utility modules for tenant creation/cleanup, database-specific helpers, and common test patterns.

**See**: `spec/support/` for helper implementations.

## Test Architecture Decisions

**Why database-specific test suites?**: Each adapter has fundamentally different isolation mechanisms (PostgreSQL schemas vs MySQL databases vs SQLite files). Testing all adapters against shared examples ensures consistent behavior across implementations.

**Why `DB` environment variable?**: Allows testing same codebase against different databases without changing configuration. Critical for ensuring gem works across all supported databases.

**Commands**: See README.md for specific test execution commands.

## Common Test Patterns

### Testing Tenant Isolation

Create multiple tenants, add data in one, verify it doesn't appear in others. See `spec/integration/` for isolation test examples.

### Testing Callbacks

Set callbacks on adapter, trigger tenant operations, verify callbacks execute. See `spec/adapters/abstract_adapter_spec.rb`.

### Testing Error Handling

Use `expect { }.to raise_error(Apartment::TenantNotFound)` pattern for exception testing. See adapter specs for error handling examples.

### Testing Excluded Models

Configure excluded models, create data in one tenant, verify global accessibility. See `spec/apartment/` for excluded model tests.

### Testing Thread Safety

Spawn threads with different tenants, verify isolation maintained. See `spec/integration/` for thread safety patterns.

## Test Data Management

### Creating Test Tenants

Use `before` hooks to create test tenants array and `after` hooks to clean up. See `spec/support/apartment_helpers.rb` for helper patterns.

### Using Factories

Use FactoryBot within tenant switch blocks. Define factories in `spec/support/factories.rb`.

## Testing Anti-Patterns

### ❌ Not Cleaning Up Tenants

**Problem**: Leaves test tenants in database

**Fix**: Always clean up in `after` hook. See `spec_helper.rb` for cleanup patterns.

### ❌ Not Resetting Tenant Context

**Problem**: Test leaves tenant context changed

**Fix**: Use `before { Apartment::Tenant.reset }` or block-based switching. See `spec_helper.rb` for reset configuration.

### ❌ Database-Specific Tests Without Conditionals

**Problem**: PostgreSQL-only tests run on all databases

**Fix**: Use conditional tests with `if: postgresql?` guards. See `spec/adapters/` for examples.

## Debugging Tests

### Enable Verbose Logging

Set `config.active_record_log = true` and configure `ActiveRecord::Base.logger`. See `spec_helper.rb` for configuration patterns.

### Inspect Tenant State

Use `Apartment::Tenant.current`, `Apartment.tenant_names`, and `Apartment::Tenant.adapter.class` for debugging.

### Database Inspection

Query `information_schema.schemata` (PostgreSQL) or `SHOW DATABASES` (MySQL) to inspect tenant state. See adapter specs for examples.

## Known Issues & Workarounds

### Issue: Tests Fail Due to Tenant Leakage

**Symptom**: Random test failures, tenants from previous tests exist

**Cause**: Inadequate cleanup in `after` hooks

**Solution**: Force cleanup in `after(:each)` hooks. Reset tenant and drop all test tenants by prefix. See `spec_helper.rb`.

### Issue: Database Connection Exhaustion

**Symptom**: Tests hang or fail with connection errors

**Cause**: Too many simultaneous tenant switches (MySQL)

**Solution**: Reduce parallelization or increase connection pool size in `spec/config/database.yml`.

### Issue: Slow Test Suite

**Symptom**: Tests take minutes to run

**Causes**: Creating/dropping tenants repeatedly, not using transactions, running full migrations

**Solutions**: Use transactional fixtures, cache test tenant creation in `before(:suite)`, share tenants for read-only tests. See `spec_helper.rb` for patterns.

## Test Coverage

Current coverage areas:
- ✅ Adapter operations (create, switch, drop)
- ✅ Elevator tenant detection
- ✅ Configuration handling
- ✅ Excluded models
- ✅ Callbacks
- ✅ Error handling
- ⚠️ Thread safety (some coverage)
- ⚠️ Migration scenarios (partial)
- ❌ Fiber safety (not tested in v3)

Areas needing more coverage:
- Concurrent tenant access patterns
- Large-scale tenant creation (100+ tenants)
- Connection pool behavior under load
- Memory leak detection
- Performance benchmarks

## Best Practices

1. **Always clean up**: Drop test tenants in `after` hooks
2. **Reset tenant context**: Use `before { Apartment::Tenant.reset }`
3. **Use block-based switching**: Ensures automatic cleanup
4. **Isolate database-specific tests**: Use conditionals for adapter-specific behavior
5. **Mock external dependencies**: Don't hit real external services
6. **Use shared examples**: Ensure consistent adapter behavior
7. **Test error paths**: Not just happy paths
8. **Document why, not what**: Comments should explain intent

## References

- RSpec documentation: https://rspec.info/
- FactoryBot: https://github.com/thoughtbot/factory_bot
- Database Cleaner: https://github.com/DatabaseCleaner/database_cleaner
- Rack::Test: https://github.com/rack/rack-test
