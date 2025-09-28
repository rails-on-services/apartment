# spec/CLAUDE.md - Apartment Testing Context

This directory contains comprehensive test coverage for the Apartment gem refactor.

## Test Structure

### Core Test Files

- **`tenant_switching_spec.rb`** - Basic tenant switching and connection behavior
- **`connection_pool_isolation_spec.rb`** - Database-agnostic architecture tests
- **`postgresql_stress_spec.rb`** - High-load and concurrency stress tests

### Test Configuration

- **`rails_helper.rb`** - Rails testing environment setup
- **`spec_helper.rb`** - Core RSpec configuration
- **`dummy/`** - Minimal Rails app for testing

## Running Tests

### Database-Specific Testing

```bash
# PostgreSQL (recommended for full testing)
DATABASE_ENGINE=postgresql bundle exec appraisal rails-8-0-postgresql rspec

# MySQL (connection pool testing)
DATABASE_ENGINE=mysql bundle exec appraisal rails-8-0-mysql rspec

# SQLite (fast database-agnostic testing)
bundle exec appraisal rails-8-0-sqlite3 rspec
```

### Test Categories

**Database-Agnostic Tests** (18 specs):
- Connection pool isolation and reuse
- Thread safety with concurrent access
- Tenant strategy configuration
- Block-scoped switching behavior
- Exception handling and cleanup

**PostgreSQL Stress Tests** (7 specs):
- High-volume tenant switching (100+ operations)
- Concurrent multi-threaded access (20+ threads)
- Memory leak prevention
- Connection specification consistency
- Exception handling under load

**Basic Functionality Tests** (9 specs):
- Core tenant switching operations
- Connection pool management
- Pinned model behavior
- Database-specific operations

## Test Patterns

### Database-Agnostic Testing

Tests that don't require actual database connections:

```ruby
it 'creates separate connection pools for different tenants' do
  Apartment::Tenant.switch!('tenant1')
  pool1 = ActiveRecord::Base.connection_pool

  Apartment::Tenant.switch!('tenant2')
  pool2 = ActiveRecord::Base.connection_pool

  expect(pool1.object_id).not_to eq(pool2.object_id)
end
```

### Thread Safety Testing

Concurrent access verification:

```ruby
it 'isolates tenant context between threads' do
  results = Concurrent::Array.new

  threads = 3.times.map do |i|
    Thread.new do
      Apartment::Tenant.switch("tenant#{i}") do
        results << Apartment::Tenant.current
      end
    end
  end

  threads.each(&:join)
  expect(results.sort).to eq(%w[tenant0 tenant1 tenant2])
end
```

### Stress Testing

High-load scenario validation:

```ruby
it 'handles rapid tenant switches without memory leaks' do
  100.times do |i|
    tenant_name = "stress_tenant_#{(i % 50) + 1}"
    Apartment::Tenant.switch!(tenant_name)
    expect(Apartment::Tenant.current).to eq(tenant_name)
  end
end
```

## Test Database Configuration

### Multiple Database Support

The test suite uses `DATABASE_ENGINE` environment variable to configure database adapters:

- **postgresql**: Full feature testing with schema isolation
- **mysql**: Database-per-tenant testing
- **sqlite3**: Fast in-memory testing

### Appraisal Integration

Tests run against multiple Rails versions using appraisal gemfiles:

- `rails-8-0-postgresql`
- `rails-8-0-mysql`
- `rails-8-0-sqlite3`

## Writing New Tests

### Test Categories

1. **Architecture Tests**: Connection pool behavior, tenant isolation
2. **API Tests**: Public interface behavior and contracts
3. **Integration Tests**: Database-specific functionality
4. **Stress Tests**: Performance and concurrency validation

### Test Principles

- **Database Agnostic**: Prefer tests that work across all databases
- **Thread Safe**: Test concurrent access scenarios
- **Exception Safe**: Verify cleanup on errors
- **Performance Aware**: Include memory and speed considerations

### Example Test Structure

```ruby
RSpec.describe 'Feature Name' do
  before(:all) do
    Apartment.configure do |config|
      config.tenant_strategy = :schema
      config.tenants_provider = -> { %w[tenant1 tenant2] }
    end
  end

  before { Apartment::Tenant.reset }

  describe 'specific behavior' do
    it 'does something correctly' do
      # Test implementation
    end
  end
end
```

## Performance Testing

### Metrics to Track

- **Memory Usage**: Connection pool growth and cleanup
- **Thread Safety**: Concurrent access without race conditions
- **Switching Speed**: Tenant change performance
- **Scale**: Behavior with many tenants (50+)

### Stress Test Coverage

- ✅ 100+ rapid tenant switches
- ✅ 20+ concurrent threads
- ✅ 50+ tenant configurations
- ✅ Exception scenarios under load
- ✅ Memory leak prevention

## Debugging Test Issues

### Common Problems

1. **Database Connection Errors**: Ensure test database exists
2. **Thread Race Conditions**: Use proper synchronization primitives
3. **Memory Leaks**: Check connection pool cleanup
4. **Configuration Issues**: Verify `DATABASE_ENGINE` is set correctly

### Debugging Tools

```bash
# Run with detailed output
bundle exec rspec --format documentation

# Run specific test file
bundle exec rspec spec/apartment/connection_pool_isolation_spec.rb

# Run with timing information
bundle exec rspec --profile 10
```