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

**Key patterns**:
```ruby
RSpec.describe Apartment::Adapters::PostgresqlAdapter do
  subject { described_class.new(config) }

  describe '#create' do
    it 'creates a new schema' do
      subject.create('test_tenant')
      # Verify schema exists
    end

    it 'raises TenantExists if schema exists' do
      subject.create('test_tenant')
      expect { subject.create('test_tenant') }.to raise_error(Apartment::TenantExists)
    end
  end
end
```

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

**Key patterns**:
```ruby
RSpec.describe Apartment::Elevators::Subdomain do
  let(:app) { ->(env) { [200, {}, ['OK']] } }
  let(:elevator) { described_class.new(app) }

  def make_request(host)
    env = Rack::MockRequest.env_for("http://#{host}/")
    elevator.call(env)
  end

  before { allow(Apartment::Tenant).to receive(:switch).and_yield }

  it 'switches based on subdomain' do
    expect(Apartment::Tenant).to receive(:switch).with('acme')
    make_request('acme.example.com')
  end
end
```

### Integration Tests (spec/integration/)

**Purpose**: Full-stack scenarios with real database operations

**What's tested**:
- Complete request → response flows
- Middleware + adapter interaction
- Multi-tenant data isolation
- Concurrent tenant access
- Migration scenarios

**Key patterns**:
```ruby
RSpec.describe 'Multi-tenant data isolation', type: :integration do
  before do
    Apartment::Tenant.create('tenant_a')
    Apartment::Tenant.create('tenant_b')
  end

  it 'isolates data between tenants' do
    Apartment::Tenant.switch('tenant_a') do
      User.create!(name: 'Tenant A User')
    end

    Apartment::Tenant.switch('tenant_b') do
      expect(User.count).to eq(0)
    end
  end
end
```

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

**Key setup**:
```ruby
RSpec.configure do |config|
  # Database selection via env var
  config.before(:suite) do
    database = ENV['DB'] || 'postgresql'
    # Load appropriate database config
  end

  # Reset tenant before each test
  config.before(:each) do
    Apartment::Tenant.reset
  end

  # Cleanup after tests
  config.after(:each) do
    # Drop test tenants
  end
end
```

### Database Configuration (spec/config/)

**Files**:
- `database.yml` - Multi-database configuration
- Environment-specific configs

**Databases supported**:
- PostgreSQL (default)
- MySQL
- SQLite

**Selection**: Via `DB` environment variable

```bash
# Run with PostgreSQL (default)
bundle exec rspec

# Run with MySQL
DB=mysql bundle exec rspec

# Run with SQLite
DB=sqlite3 bundle exec rspec
```

## Shared Examples (spec/examples/)

**Purpose**: Reusable test patterns for adapters

**Files**:
- `adapter_examples.rb` - Common adapter behavior
- `schema_examples.rb` - Schema import/export
- `seed_examples.rb` - Seed data handling

**Usage**:
```ruby
RSpec.describe Apartment::Adapters::PostgresqlAdapter do
  it_behaves_like 'a generic apartment adapter'
  it_behaves_like 'an adapter with schema support'
end
```

**Benefits**:
- ✅ Consistent testing across adapters
- ✅ Reduce duplication
- ✅ Ensure all adapters meet contract

## Support Files (spec/support/)

**helpers.rb**: Test utility methods
**database_helpers.rb**: Database-specific test utilities
**apartment_helpers.rb**: Tenant creation/cleanup helpers

**Example helpers**:
```ruby
module ApartmentHelpers
  def create_test_tenant(name)
    Apartment::Tenant.create(name) unless tenant_exists?(name)
  end

  def tenant_exists?(name)
    Apartment.tenant_names.include?(name)
  end

  def with_tenant(name)
    Apartment::Tenant.switch(name) { yield }
  end
end
```

## Running Tests

### All Tests

```bash
bundle exec rspec
```

### Specific Database

```bash
DB=postgresql bundle exec rspec
DB=mysql bundle exec rspec
DB=sqlite3 bundle exec rspec
```

### Specific Test File

```bash
bundle exec rspec spec/adapters/postgresql_adapter_spec.rb
```

### Specific Test

```bash
bundle exec rspec spec/tenant_spec.rb:42
```

### With Coverage

```bash
COVERAGE=true bundle exec rspec
```

## Common Test Patterns

### Testing Tenant Isolation

```ruby
it 'isolates tenant data' do
  Apartment::Tenant.create('tenant_a')
  Apartment::Tenant.create('tenant_b')

  # Create data in tenant_a
  Apartment::Tenant.switch('tenant_a') do
    User.create!(name: 'User A')
    expect(User.count).to eq(1)
  end

  # Verify isolation in tenant_b
  Apartment::Tenant.switch('tenant_b') do
    expect(User.count).to eq(0)
  end
end
```

### Testing Callbacks

```ruby
it 'fires callbacks on tenant creation' do
  callback_fired = false

  Apartment::Adapters::AbstractAdapter.set_callback :create, :after do
    callback_fired = true
  end

  Apartment::Tenant.create('test_tenant')
  expect(callback_fired).to be true
end
```

### Testing Error Handling

```ruby
it 'raises TenantNotFound when switching to nonexistent tenant' do
  expect {
    Apartment::Tenant.switch('nonexistent') { }
  }.to raise_error(Apartment::TenantNotFound)
end
```

### Testing Excluded Models

```ruby
it 'bypasses tenant switching for excluded models' do
  Apartment.excluded_models = ['Company']

  Apartment::Tenant.switch('tenant_a') do
    Company.create!(name: 'Global Company')
  end

  Apartment::Tenant.switch('tenant_b') do
    # Company data is global, not tenant-specific
    expect(Company.count).to eq(1)
  end
end
```

### Testing Thread Safety

```ruby
it 'maintains tenant isolation across threads' do
  Apartment::Tenant.create('tenant_a')
  Apartment::Tenant.create('tenant_b')

  threads = []

  threads << Thread.new do
    Apartment::Tenant.switch('tenant_a') do
      sleep 0.1
      expect(Apartment::Tenant.current).to eq('tenant_a')
    end
  end

  threads << Thread.new do
    Apartment::Tenant.switch('tenant_b') do
      sleep 0.1
      expect(Apartment::Tenant.current).to eq('tenant_b')
    end
  end

  threads.each(&:join)
end
```

## Test Data Management

### Creating Test Tenants

```ruby
before do
  @test_tenants = ['test_a', 'test_b', 'test_c']
  @test_tenants.each { |t| Apartment::Tenant.create(t) }
end

after do
  @test_tenants.each { |t| Apartment::Tenant.drop(t) }
end
```

### Using Factories

```ruby
# spec/support/factories.rb
FactoryBot.define do
  factory :user do
    name { Faker::Name.name }
    email { Faker::Internet.email }
  end
end

# In spec
Apartment::Tenant.switch('test_tenant') do
  user = create(:user)
  expect(user).to be_persisted
end
```

## Testing Anti-Patterns

### ❌ Not Cleaning Up Tenants

```ruby
# BAD: Leaves test tenants in database
it 'creates a tenant' do
  Apartment::Tenant.create('leaked_tenant')
end
```

**Fix**: Always clean up in `after` hook

### ❌ Not Resetting Tenant Context

```ruby
# BAD: Test leaves tenant context changed
it 'switches tenant' do
  Apartment::Tenant.switch!('some_tenant')
  # Test ends without resetting
end
```

**Fix**: Use `before { Apartment::Tenant.reset }` or block-based switching

### ❌ Database-Specific Tests Without Conditionals

```ruby
# BAD: PostgreSQL-only test runs on all databases
it 'uses schemas' do
  # This will fail on MySQL/SQLite
  expect(Apartment::Tenant.adapter).to respond_to(:schemas)
end
```

**Fix**: Use conditional tests

```ruby
it 'uses schemas', if: postgresql? do
  expect(Apartment::Tenant.adapter).to respond_to(:schemas)
end
```

## Debugging Tests

### Enable Verbose Logging

```ruby
# In spec_helper.rb or specific spec
Apartment.configure do |config|
  config.active_record_log = true
end

ActiveRecord::Base.logger = Logger.new(STDOUT)
```

### Inspect Tenant State

```ruby
# Add to failing test
puts "Current tenant: #{Apartment::Tenant.current}"
puts "Available tenants: #{Apartment.tenant_names.inspect}"
puts "Adapter class: #{Apartment::Tenant.adapter.class.name}"
```

### Database Inspection

```ruby
# PostgreSQL: List schemas
schemas = ActiveRecord::Base.connection.execute(
  "SELECT schema_name FROM information_schema.schemata"
).map { |r| r['schema_name'] }
puts "Schemas: #{schemas.inspect}"

# MySQL: List databases
databases = ActiveRecord::Base.connection.execute("SHOW DATABASES")
  .map { |r| r.first }
puts "Databases: #{databases.inspect}"
```

## Known Issues & Workarounds

### Issue: Tests Fail Due to Tenant Leakage

**Symptom**: Random test failures, tenants from previous tests exist

**Cause**: Inadequate cleanup in `after` hooks

**Solution**:
```ruby
config.after(:each) do
  # Force cleanup
  Apartment::Tenant.reset

  # Drop all test tenants
  Apartment.tenant_names.each do |tenant|
    Apartment::Tenant.drop(tenant) if tenant.start_with?('test_')
  end
end
```

### Issue: Database Connection Exhaustion

**Symptom**: Tests hang or fail with connection errors

**Cause**: Too many simultaneous tenant switches (MySQL)

**Solution**: Reduce parallelization or increase connection pool

```yaml
# spec/config/database.yml
test:
  pool: 50  # Increase pool size
```

### Issue: Slow Test Suite

**Symptom**: Tests take minutes to run

**Causes**:
- Creating/dropping tenants repeatedly
- Not using transactions
- Running full migrations

**Solutions**:
```ruby
# Use database cleaner with transactions
config.use_transactional_fixtures = true

# Cache test tenant creation
config.before(:suite) do
  # Create common test tenants once
  Apartment::Tenant.create('common_test_tenant')
end

# Use shared tenant for read-only tests
it 'reads data' do
  Apartment::Tenant.switch('common_test_tenant') do
    # Read-only operations
  end
end
```

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
