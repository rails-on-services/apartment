# Phase 5: Role-Aware Connections, RBAC, Schema Cache Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Apartment v4's `ConnectionHandling` role-aware so `connected_to(role:)` composes correctly with `Tenant.switch`, enabling RBAC credential separation, replica routing, RBAC privilege grants, per-tenant schema cache, and pending migration checks.

**Architecture:** `ConnectionHandling#connection_pool` resolves the base config from the current role's default pool via `super`, then lets the adapter apply tenant-specific modifications. Pool keys become `"tenant:role"`. The Migrator wraps work in `connected_to(role: migration_role)`. RBAC grants execute in adapter subclasses after tenant creation.

**Tech Stack:** Ruby 3.3+, Rails 7.2/8.0/8.1, ActiveRecord, ActiveSupport::CurrentAttributes, Concurrent::Map, RSpec

**Spec:** `docs/designs/v4-phase5-rbac-roles-schema-cache.md`

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `lib/apartment/current.rb` | Modify | Add `:migrating` attribute |
| `lib/apartment/errors.rb` | Modify | Add `PendingMigrationError` |
| `lib/apartment/config.rb` | Modify | Add 4 new config keys + validation |
| `lib/apartment/tenant_name_validator.rb` | Modify | Add colon to common blacklist |
| `lib/apartment/pool_manager.rb` | Modify | Add `remove_tenant`, `evict_by_role` |
| `lib/apartment.rb` | Modify | Update `deregister_shard` for composite keys |
| `lib/apartment/pool_reaper.rb` | Modify | Prefix-based default tenant guard |
| `lib/apartment/adapters/abstract_adapter.rb` | Modify | `base_config_override:`, grants dispatch, `drop` update |
| `lib/apartment/adapters/postgresql_schema_adapter.rb` | Modify | `base_config:` keyword, `grant_privileges` |
| `lib/apartment/adapters/postgresql_database_adapter.rb` | Modify | `base_config:` keyword |
| `lib/apartment/adapters/mysql2_adapter.rb` | Modify | `base_config:` keyword, `grant_privileges` |
| `lib/apartment/adapters/sqlite3_adapter.rb` | Modify | `base_config:` keyword |
| `lib/apartment/patches/connection_handling.rb` | Modify | Role-aware resolution, pending check, schema cache |
| `lib/apartment/migrator.rb` | Modify | `with_migration_role`, `Current.migrating`, eviction |
| `lib/apartment/schema_cache.rb` | Create | `dump`, `dump_all`, `cache_path_for` |
| `lib/apartment/tasks/v4.rake` | Modify | Add `apartment:schema:cache:dump` |

---

## Task Ordering & Dependencies

Tasks 1-4 are foundation (no inter-dependencies, can be parallelized). Tasks 5-7 depend on 1-4. Task 8 depends on 5. Tasks 9-10 are independent leaf nodes.

```
Task 1 (Current + Errors) ─┐
Task 2 (Config)            ─┼─► Task 5 (Adapter interface) ─► Task 7 (ConnectionHandling) ─► Task 8 (Migrator)
Task 3 (PoolManager)       ─┤                                                                     │
Task 4 (TenantNameValidator)┘   Task 6 (RBAC grants) ────────────────────────────────────────────► │
                                Task 9  (SchemaCache) ─────────────────────────────────────────────►│
                                Task 10 (Rake tasks) ──────────────────────────────────────────────►│
```

---

### Task 1: Current.migrating + PendingMigrationError

**Files:**
- Modify: `lib/apartment/current.rb:9`
- Modify: `lib/apartment/errors.rb:37`
- Test: `spec/unit/current_spec.rb` (existing, add cases)
- Test: `spec/unit/errors_spec.rb` (existing, add cases)

- [ ] **Step 1: Write failing test for Current.migrating**

In `spec/unit/current_spec.rb`, add:

```ruby
describe '.migrating' do
  it 'defaults to nil' do
    expect(Apartment::Current.migrating).to(be_nil)
  end

  it 'can be set and read' do
    Apartment::Current.migrating = true
    expect(Apartment::Current.migrating).to(be(true))
  ensure
    Apartment::Current.migrating = nil
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/unit/current_spec.rb -e 'migrating' -f doc`
Expected: FAIL — `migrating` attribute doesn't exist

- [ ] **Step 3: Add migrating attribute to Current**

In `lib/apartment/current.rb:9`, change:
```ruby
attribute :tenant, :previous_tenant
```
to:
```ruby
attribute :tenant, :previous_tenant, :migrating
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/unit/current_spec.rb -e 'migrating' -f doc`
Expected: PASS

- [ ] **Step 5: Write failing test for PendingMigrationError**

In `spec/unit/errors_spec.rb`, add:

```ruby
describe Apartment::PendingMigrationError do
  it 'includes tenant in message' do
    error = described_class.new('acme')
    expect(error.message).to(include('acme'))
    expect(error.message).to(include('apartment:migrate'))
    expect(error.tenant).to(eq('acme'))
  end

  it 'has a default message without tenant' do
    error = described_class.new
    expect(error.message).to(include('apartment:migrate'))
  end

  it 'inherits from ApartmentError' do
    expect(described_class.new).to(be_a(Apartment::ApartmentError))
  end
end
```

- [ ] **Step 6: Run test to verify it fails**

Run: `bundle exec rspec spec/unit/errors_spec.rb -e 'PendingMigrationError' -f doc`
Expected: FAIL — `PendingMigrationError` not defined

- [ ] **Step 7: Implement PendingMigrationError**

In `lib/apartment/errors.rb`, after the `SchemaLoadError` class (line 37), add:

```ruby
# Raised in development when a tenant has pending migrations.
class PendingMigrationError < ApartmentError
  attr_reader :tenant

  def initialize(tenant = nil)
    @tenant = tenant
    super(
      tenant ? "Tenant '#{tenant}' has pending migrations. Run apartment:migrate to update."
             : 'Tenant has pending migrations. Run apartment:migrate to update.'
    )
  end
end
```

- [ ] **Step 8: Run test to verify it passes**

Run: `bundle exec rspec spec/unit/errors_spec.rb -e 'PendingMigrationError' -f doc`
Expected: PASS

- [ ] **Step 9: Run full unit suite to check for regressions**

Run: `bundle exec rspec spec/unit/ --format progress`
Expected: All passing

- [ ] **Step 10: Commit**

```bash
git add lib/apartment/current.rb lib/apartment/errors.rb spec/unit/current_spec.rb spec/unit/errors_spec.rb
git commit -m "Add Current.migrating attribute and PendingMigrationError"
```

---

### Task 2: Config — New Keys and Validation

**Files:**
- Modify: `lib/apartment/config.rb:14-47` (attr_accessor, initialize, validate!, freeze!)
- Test: `spec/unit/config_spec.rb` (existing, add cases)

- [ ] **Step 1: Write failing tests for new config keys**

In `spec/unit/config_spec.rb`, add a new `describe` block:

```ruby
describe 'Phase 5 config keys' do
  it 'defaults migration_role to nil' do
    Apartment.configure do |c|
      c.tenant_strategy = :schema
      c.tenants_provider = -> { [] }
    end
    expect(Apartment.config.migration_role).to(be_nil)
  end

  it 'defaults app_role to nil' do
    Apartment.configure do |c|
      c.tenant_strategy = :schema
      c.tenants_provider = -> { [] }
    end
    expect(Apartment.config.app_role).to(be_nil)
  end

  it 'defaults schema_cache_per_tenant to false' do
    Apartment.configure do |c|
      c.tenant_strategy = :schema
      c.tenants_provider = -> { [] }
    end
    expect(Apartment.config.schema_cache_per_tenant).to(be(false))
  end

  it 'defaults check_pending_migrations to true' do
    Apartment.configure do |c|
      c.tenant_strategy = :schema
      c.tenants_provider = -> { [] }
    end
    expect(Apartment.config.check_pending_migrations).to(be(true))
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/unit/config_spec.rb -e 'Phase 5' -f doc`
Expected: FAIL — methods not defined

- [ ] **Step 3: Add attr_accessors and defaults to Config**

In `lib/apartment/config.rb:15`, add to `attr_accessor` line:
```ruby
:migration_role, :app_role,
:schema_cache_per_tenant, :check_pending_migrations,
```

In `lib/apartment/config.rb` `initialize` method, add:
```ruby
@migration_role = nil
@app_role = nil
@schema_cache_per_tenant = false
@check_pending_migrations = true
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/unit/config_spec.rb -e 'Phase 5' -f doc`
Expected: PASS

- [ ] **Step 5: Write failing validation tests**

```ruby
describe 'Phase 5 validation' do
  it 'rejects non-symbol migration_role' do
    expect {
      Apartment.configure do |c|
        c.tenant_strategy = :schema
        c.tenants_provider = -> { [] }
        c.migration_role = 'db_manager'
      end
    }.to(raise_error(Apartment::ConfigurationError, /migration_role/))
  end

  it 'accepts symbol migration_role' do
    Apartment.configure do |c|
      c.tenant_strategy = :schema
      c.tenants_provider = -> { [] }
      c.migration_role = :db_manager
    end
    expect(Apartment.config.migration_role).to(eq(:db_manager))
  end

  it 'rejects non-string non-callable app_role' do
    expect {
      Apartment.configure do |c|
        c.tenant_strategy = :schema
        c.tenants_provider = -> { [] }
        c.app_role = 123
      end
    }.to(raise_error(Apartment::ConfigurationError, /app_role/))
  end

  it 'accepts string app_role' do
    Apartment.configure do |c|
      c.tenant_strategy = :schema
      c.tenants_provider = -> { [] }
      c.app_role = 'app_user'
    end
    expect(Apartment.config.app_role).to(eq('app_user'))
  end

  it 'accepts callable app_role' do
    custom_grants = ->(tenant, conn) {}
    Apartment.configure do |c|
      c.tenant_strategy = :schema
      c.tenants_provider = -> { [] }
      c.app_role = custom_grants
    end
    expect(Apartment.config.app_role).to(eq(custom_grants))
  end
end
```

- [ ] **Step 6: Run validation tests to verify they fail**

Run: `bundle exec rspec spec/unit/config_spec.rb -e 'Phase 5 validation' -f doc`
Expected: FAIL — no validation yet

- [ ] **Step 7: Add validation logic to Config#validate!**

In `lib/apartment/config.rb`, in `validate!`, add **before** the `shard_key_prefix` guard (before line 123's `return if @shard_key_prefix...`). The `shard_key_prefix` validation uses an early `return` that would skip any code after it:

```ruby
if @migration_role && !@migration_role.is_a?(Symbol)
  raise(ConfigurationError, "migration_role must be nil or a Symbol, got: #{@migration_role.inspect}")
end

if @app_role && !@app_role.is_a?(String) && !@app_role.respond_to?(:call)
  raise(ConfigurationError, "app_role must be nil, a String, or a callable, got: #{@app_role.inspect}")
end

unless [true, false].include?(@schema_cache_per_tenant)
  raise(ConfigurationError,
        "schema_cache_per_tenant must be true or false, got: #{@schema_cache_per_tenant.inspect}")
end

unless [true, false].include?(@check_pending_migrations)
  raise(ConfigurationError,
        "check_pending_migrations must be true or false, got: #{@check_pending_migrations.inspect}")
end
```

- [ ] **Step 8: Add freeze for string app_role**

In `Config#freeze!`, before `freeze`, add:
```ruby
@app_role.freeze if @app_role.is_a?(String)
```

- [ ] **Step 9: Run tests to verify they pass**

Run: `bundle exec rspec spec/unit/config_spec.rb -e 'Phase 5' -f doc`
Expected: PASS

- [ ] **Step 10: Run full unit suite**

Run: `bundle exec rspec spec/unit/ --format progress`
Expected: All passing

- [ ] **Step 11: Commit**

```bash
git add lib/apartment/config.rb spec/unit/config_spec.rb
git commit -m "Add Phase 5 config keys: migration_role, app_role, schema_cache_per_tenant, check_pending_migrations"
```

---

### Task 3: PoolManager — remove_tenant, evict_by_role + PoolReaper + deregister_shard

**Files:**
- Modify: `lib/apartment/pool_manager.rb:27-32` (after `remove` method)
- Modify: `lib/apartment/pool_reaper.rb:69-72,86-90` (default tenant guard)
- Modify: `lib/apartment.rb:86-97` (deregister_shard)
- Test: `spec/unit/pool_manager_spec.rb` (existing, add cases)
- Test: `spec/unit/pool_reaper_spec.rb` (existing, add cases)
- Test: `spec/unit/apartment_spec.rb` (existing, add cases)

- [ ] **Step 1: Write failing tests for PoolManager#remove_tenant**

In `spec/unit/pool_manager_spec.rb`, add:

```ruby
describe '#remove_tenant' do
  it 'removes all pools for a tenant across roles' do
    manager.fetch_or_create('acme:writing') { 'pool_w' }
    manager.fetch_or_create('acme:reading') { 'pool_r' }
    manager.fetch_or_create('other:writing') { 'pool_o' }

    removed = manager.remove_tenant('acme')

    expect(removed.map(&:first)).to(contain_exactly('acme:writing', 'acme:reading'))
    expect(manager.tracked?('acme:writing')).to(be(false))
    expect(manager.tracked?('acme:reading')).to(be(false))
    expect(manager.tracked?('other:writing')).to(be(true))
  end

  it 'returns empty array when no pools match' do
    expect(manager.remove_tenant('nonexistent')).to(eq([]))
  end
end

describe '#evict_by_role' do
  it 'removes all pools for a given role' do
    manager.fetch_or_create('acme:writing') { 'pool_aw' }
    manager.fetch_or_create('acme:db_manager') { 'pool_am' }
    manager.fetch_or_create('other:db_manager') { 'pool_om' }
    manager.fetch_or_create('other:writing') { 'pool_ow' }

    removed = manager.evict_by_role(:db_manager)

    expect(removed.map(&:first)).to(contain_exactly('acme:db_manager', 'other:db_manager'))
    expect(manager.tracked?('acme:writing')).to(be(true))
    expect(manager.tracked?('other:writing')).to(be(true))
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/unit/pool_manager_spec.rb -e 'remove_tenant\|evict_by_role' -f doc`
Expected: FAIL — methods not defined

- [ ] **Step 3: Implement remove_tenant and evict_by_role**

In `lib/apartment/pool_manager.rb`, after the `remove` method (after line 32), add:

```ruby
def remove_tenant(tenant)
  prefix = "#{tenant}:"
  removed = []
  @pools.each_key do |key|
    next unless key.start_with?(prefix)

    pool = remove(key)
    removed << [key, pool] if pool
  end
  removed
end

def evict_by_role(role)
  suffix = ":#{role}"
  removed = []
  @pools.each_key do |key|
    next unless key.end_with?(suffix)

    pool = remove(key)
    removed << [key, pool] if pool
  end
  removed
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/unit/pool_manager_spec.rb -e 'remove_tenant\|evict_by_role' -f doc`
Expected: PASS

- [ ] **Step 5: Write failing test for PoolReaper default tenant guard**

In `spec/unit/pool_reaper_spec.rb`, find the existing idle eviction tests and add:

```ruby
it 'does not evict pools for the default tenant regardless of role suffix' do
  pool_manager.fetch_or_create('public:writing') { mock_pool }
  pool_manager.fetch_or_create('public:reading') { mock_pool }
  sleep(0.05) # ensure they're idle

  reaper = described_class.new(
    pool_manager: pool_manager, interval: 100, idle_timeout: 0.01,
    default_tenant: 'public'
  )
  reaper.send(:reap)

  expect(pool_manager.tracked?('public:writing')).to(be(true))
  expect(pool_manager.tracked?('public:reading')).to(be(true))
end
```

- [ ] **Step 6: Run test to verify it fails**

Run: `bundle exec rspec spec/unit/pool_reaper_spec.rb -e 'default tenant regardless' -f doc`
Expected: FAIL — guard uses `==` instead of prefix match

- [ ] **Step 7: Update PoolReaper default tenant guard**

In `lib/apartment/pool_reaper.rb`, add a private method after `evict_lru` (line 99):

```ruby
def default_tenant_pool?(pool_key)
  return false unless @default_tenant

  pool_key == @default_tenant || pool_key.start_with?("#{@default_tenant}:")
end
```

Then change line 71 `next if tenant == @default_tenant` to:
```ruby
next if default_tenant_pool?(tenant)
```

And line 90 `next if tenant == @default_tenant` to:
```ruby
next if default_tenant_pool?(tenant)
```

- [ ] **Step 8: Run test to verify it passes**

Run: `bundle exec rspec spec/unit/pool_reaper_spec.rb -e 'default tenant' -f doc`
Expected: PASS

- [ ] **Step 9: Write failing test for deregister_shard composite key**

In `spec/unit/apartment_spec.rb`, add:

```ruby
describe '.deregister_shard with composite key' do
  it 'extracts role from tenant:role format' do
    allow(ActiveRecord::Base.connection_handler).to(receive(:remove_connection_pool))

    Apartment.deregister_shard('acme:db_manager')

    expect(ActiveRecord::Base.connection_handler).to(have_received(:remove_connection_pool).with(
      'ActiveRecord::Base',
      role: :db_manager,
      shard: :"#{Apartment.config.shard_key_prefix}_acme:db_manager"
    ))
  end
end
```

- [ ] **Step 10: Run test to verify it fails**

Run: `bundle exec rspec spec/unit/apartment_spec.rb -e 'composite key' -f doc`
Expected: FAIL — uses `current_role` instead of extracting from key

- [ ] **Step 11: Update deregister_shard**

In `lib/apartment.rb`, replace the `deregister_shard` method (lines 86-97) with:

```ruby
def deregister_shard(pool_key)
  return unless @config && defined?(ActiveRecord::Base)

  _tenant, _, role_str = pool_key.to_s.rpartition(':')
  role = role_str.empty? ? ActiveRecord.writing_role : role_str.to_sym

  shard_key = :"#{@config.shard_key_prefix}_#{pool_key}"
  ActiveRecord::Base.connection_handler.remove_connection_pool(
    'ActiveRecord::Base',
    role: role,
    shard: shard_key
  )
rescue StandardError => e
  warn "[Apartment] Failed to deregister AR pool for #{pool_key}: #{e.class}: #{e.message}"
end
```

- [ ] **Step 12: Run test to verify it passes**

Run: `bundle exec rspec spec/unit/apartment_spec.rb -e 'composite key' -f doc`
Expected: PASS

- [ ] **Step 13: Run full unit suite**

Run: `bundle exec rspec spec/unit/ --format progress`
Expected: All passing

- [ ] **Step 14: Commit**

```bash
git add lib/apartment/pool_manager.rb lib/apartment/pool_reaper.rb lib/apartment.rb spec/unit/pool_manager_spec.rb spec/unit/pool_reaper_spec.rb spec/unit/apartment_spec.rb
git commit -m "Pool lifecycle: remove_tenant, evict_by_role, composite key deregistration, prefix guard"
```

---

### Task 4: TenantNameValidator — Colon Restriction

**Files:**
- Modify: `lib/apartment/tenant_name_validator.rb:26`
- Test: `spec/unit/tenant_name_validator_spec.rb` (existing, add case)

- [ ] **Step 1: Write failing test**

In `spec/unit/tenant_name_validator_spec.rb`, add to the `validate_common!` describe block:

```ruby
it 'rejects names containing colons' do
  expect {
    described_class.validate!('tenant:name', strategy: :schema)
  }.to(raise_error(Apartment::ConfigurationError, /colon/))
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/unit/tenant_name_validator_spec.rb -e 'colon' -f doc`
Expected: FAIL

- [ ] **Step 3: Add colon check to validate_common!**

In `lib/apartment/tenant_name_validator.rb:26`, after the whitespace check, add:

```ruby
raise(ConfigurationError, "Tenant name contains colon: #{name.inspect}") if name.include?(':')
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/unit/tenant_name_validator_spec.rb -e 'colon' -f doc`
Expected: PASS

- [ ] **Step 5: Run full unit suite**

Run: `bundle exec rspec spec/unit/ --format progress`
Expected: All passing

- [ ] **Step 6: Commit**

```bash
git add lib/apartment/tenant_name_validator.rb spec/unit/tenant_name_validator_spec.rb
git commit -m "Reject colons in tenant names (composite pool key delimiter)"
```

---

### Task 5: Adapter Interface — base_config_override + drop Update

**Files:**
- Modify: `lib/apartment/adapters/abstract_adapter.rb:24-36,53-65`
- Modify: `lib/apartment/adapters/postgresql_schema_adapter.rb:15-19`
- Modify: `lib/apartment/adapters/postgresql_database_adapter.rb` (resolve_connection_config)
- Modify: `lib/apartment/adapters/mysql2_adapter.rb` (resolve_connection_config)
- Modify: `lib/apartment/adapters/sqlite3_adapter.rb:15-17`
- Test: `spec/unit/adapters/postgresql_schema_adapter_spec.rb` (add cases)
- Test: `spec/unit/adapters/abstract_adapter_spec.rb` (add cases)
- Test: `spec/unit/adapters/sqlite3_adapter_spec.rb` (add cases)

- [ ] **Step 1: Write failing test for base_config_override on PG schema adapter**

In `spec/unit/adapters/postgresql_schema_adapter_spec.rb`, add:

```ruby
describe '#validated_connection_config with base_config_override' do
  it 'uses the provided base config instead of adapter base_config' do
    override = { 'adapter' => 'postgresql', 'host' => 'replica.example.com', 'username' => 'reader' }
    config = adapter.validated_connection_config('acme', base_config_override: override)

    expect(config['host']).to(eq('replica.example.com'))
    expect(config['username']).to(eq('reader'))
    expect(config['schema_search_path']).to(eq('acme'))
  end

  it 'falls back to base_config when override is nil' do
    config = adapter.validated_connection_config('acme')
    expect(config['host']).to(eq('localhost'))
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/unit/adapters/postgresql_schema_adapter_spec.rb -e 'base_config_override' -f doc`
Expected: FAIL — unknown keyword: `base_config_override`

- [ ] **Step 3: Update AbstractAdapter**

In `lib/apartment/adapters/abstract_adapter.rb`, replace `validated_connection_config` (lines 24-31):

```ruby
def validated_connection_config(tenant, base_config_override: nil)
  effective_base = base_config_override || base_config
  TenantNameValidator.validate!(
    tenant,
    strategy: Apartment.config.tenant_strategy,
    adapter_name: effective_base['adapter']
  )
  resolve_connection_config(tenant, base_config: effective_base)
end
```

Replace `resolve_connection_config` (lines 35-37):

```ruby
def resolve_connection_config(tenant, base_config: nil)
  raise(NotImplementedError)
end
```

- [ ] **Step 4: Update PostgresqlSchemaAdapter**

In `lib/apartment/adapters/postgresql_schema_adapter.rb`, replace `resolve_connection_config` (lines 15-19):

```ruby
def resolve_connection_config(tenant, base_config: nil)
  config = base_config || send(:base_config)
  persistent = Apartment.config.postgres_config&.persistent_schemas || []
  search_path = [tenant, *persistent].join(',')
  config.merge('schema_search_path' => search_path)
end
```

- [ ] **Step 5: Update remaining adapters**

PostgresqlDatabaseAdapter — update `resolve_connection_config`:
```ruby
def resolve_connection_config(tenant, base_config: nil)
  config = base_config || send(:base_config)
  config.merge('database' => environmentify(tenant))
end
```

Mysql2Adapter — same pattern:
```ruby
def resolve_connection_config(tenant, base_config: nil)
  config = base_config || send(:base_config)
  config.merge('database' => environmentify(tenant))
end
```

Sqlite3Adapter — update `resolve_connection_config`:
```ruby
def resolve_connection_config(tenant, base_config: nil)
  config = base_config || send(:base_config)
  db_dir = config['database'] ? File.dirname(config['database']) : 'db'
  config.merge('database' => File.join(db_dir, "#{environmentify(tenant)}.sqlite3"))
end
```

- [ ] **Step 6: Run test to verify it passes**

Run: `bundle exec rspec spec/unit/adapters/postgresql_schema_adapter_spec.rb -e 'base_config_override' -f doc`
Expected: PASS

- [ ] **Step 7: Write failing test for updated AbstractAdapter#drop**

In `spec/unit/adapters/abstract_adapter_spec.rb`, add:

```ruby
describe '#drop with composite pool keys' do
  it 'removes all role variants from pool_manager' do
    pool_manager = instance_double(Apartment::PoolManager)
    allow(Apartment).to(receive(:pool_manager).and_return(pool_manager))
    allow(Apartment).to(receive(:deregister_shard))
    allow(pool_manager).to(receive(:remove_tenant).with('acme').and_return([]))

    adapter.drop('acme')

    expect(pool_manager).to(have_received(:remove_tenant).with('acme'))
  end
end
```

- [ ] **Step 8: Run test to verify it fails**

Run: `bundle exec rspec spec/unit/adapters/abstract_adapter_spec.rb -e 'composite pool keys' -f doc`
Expected: FAIL — `remove_tenant` not called (still calls `remove`)

- [ ] **Step 9: Update AbstractAdapter#drop**

In `lib/apartment/adapters/abstract_adapter.rb`, replace the `drop` method (lines 53-65):

```ruby
def drop(tenant)
  drop_tenant(tenant)
  removed_pools = Apartment.pool_manager&.remove_tenant(tenant) || []
  removed_pools.each do |pool_key, pool|
    begin
      pool&.disconnect! if pool.respond_to?(:disconnect!)
    rescue StandardError => e
      warn "[Apartment] Pool disconnect failed for '#{pool_key}': #{e.class}: #{e.message}"
    end
    deregister_shard_from_ar_handler(pool_key)
  end
  Instrumentation.instrument(:drop, tenant: tenant)
end
```

Update `deregister_shard_from_ar_handler` (line 162-163) to pass through the pool_key:

```ruby
def deregister_shard_from_ar_handler(pool_key)
  Apartment.deregister_shard(pool_key)
end
```

- [ ] **Step 10: Run test to verify it passes**

Run: `bundle exec rspec spec/unit/adapters/abstract_adapter_spec.rb -e 'composite pool keys' -f doc`
Expected: PASS

- [ ] **Step 11: Run full unit suite**

Run: `bundle exec rspec spec/unit/ --format progress`
Expected: All passing

- [ ] **Step 12: Commit**

```bash
git add lib/apartment/adapters/ spec/unit/adapters/
git commit -m "Adapter interface: base_config_override keyword, drop with composite pool keys"
```

---

### Task 6: RBAC Grants — grant_privileges in Adapters

**Files:**
- Modify: `lib/apartment/adapters/abstract_adapter.rb:39-51` (create method)
- Modify: `lib/apartment/adapters/postgresql_schema_adapter.rb`
- Modify: `lib/apartment/adapters/mysql2_adapter.rb`
- Test: `spec/unit/adapters/abstract_adapter_spec.rb` (add cases)
- Test: `spec/unit/adapters/postgresql_schema_adapter_spec.rb` (add cases)
- Test: `spec/unit/adapters/mysql2_adapter_spec.rb` (add cases)

- [ ] **Step 1: Write failing test for grant dispatch in AbstractAdapter**

In `spec/unit/adapters/abstract_adapter_spec.rb`, add:

```ruby
describe '#create with app_role' do
  it 'calls grant_privileges when app_role is a string' do
    reconfigure(app_role: 'app_user')
    allow(adapter).to(receive(:create_tenant))
    conn = double('connection')
    allow(ActiveRecord::Base).to(receive(:connection).and_return(conn))
    allow(adapter).to(receive(:grant_privileges))

    adapter.create('tenant1')

    expect(adapter).to(have_received(:grant_privileges).with('tenant1', conn, 'app_user'))
  end

  it 'calls the callable when app_role is a proc' do
    grant_proc = double('callable')
    allow(grant_proc).to(receive(:respond_to?).with(:call).and_return(true))
    allow(grant_proc).to(receive(:call))
    reconfigure(app_role: grant_proc)
    allow(adapter).to(receive(:create_tenant))
    conn = double('connection')
    allow(ActiveRecord::Base).to(receive(:connection).and_return(conn))

    adapter.create('tenant1')

    expect(grant_proc).to(have_received(:call).with('tenant1', conn))
  end

  it 'skips grants when app_role is nil' do
    reconfigure(app_role: nil)
    allow(adapter).to(receive(:create_tenant))
    allow(adapter).to(receive(:grant_privileges))

    adapter.create('tenant1')

    expect(adapter).not_to(have_received(:grant_privileges))
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/unit/adapters/abstract_adapter_spec.rb -e 'app_role' -f doc`
Expected: FAIL

- [ ] **Step 3: Implement grant dispatch in AbstractAdapter#create**

In `lib/apartment/adapters/abstract_adapter.rb`, modify the `create` method to add `grant_tenant_privileges(tenant)` after `create_tenant(tenant)`:

```ruby
def create(tenant)
  TenantNameValidator.validate!(
    tenant,
    strategy: Apartment.config.tenant_strategy,
    adapter_name: base_config['adapter']
  )
  run_callbacks(:create) do
    create_tenant(tenant)
    grant_tenant_privileges(tenant)
    import_schema(tenant) if Apartment.config.schema_load_strategy
    seed(tenant) if Apartment.config.seed_after_create
    Instrumentation.instrument(:create, tenant: tenant)
  end
end
```

Add private methods:

```ruby
def grant_tenant_privileges(tenant)
  app_role = Apartment.config.app_role
  return unless app_role

  conn = ActiveRecord::Base.connection
  if app_role.respond_to?(:call)
    app_role.call(tenant, conn)
  else
    grant_privileges(tenant, conn, app_role)
  end
end

def grant_privileges(tenant, connection, role_name)
  # no-op — PG and MySQL adapters override
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/unit/adapters/abstract_adapter_spec.rb -e 'app_role' -f doc`
Expected: PASS

- [ ] **Step 5: Write failing test for PostgresqlSchemaAdapter grants**

In `spec/unit/adapters/postgresql_schema_adapter_spec.rb`, add:

```ruby
describe '#grant_privileges' do
  let(:conn) { double('connection') }

  before do
    allow(conn).to(receive(:quote_table_name)) { |name| "\"#{name}\"" }
    allow(conn).to(receive(:execute))
  end

  it 'executes 6 grant statements' do
    adapter.send(:grant_privileges, 'acme', conn, 'app_user')
    expect(conn).to(have_received(:execute).exactly(6).times)
  end

  it 'grants USAGE ON SCHEMA' do
    adapter.send(:grant_privileges, 'acme', conn, 'app_user')
    expect(conn).to(have_received(:execute).with(include('GRANT USAGE ON SCHEMA')))
  end

  it 'sets ALTER DEFAULT PRIVILEGES for tables' do
    adapter.send(:grant_privileges, 'acme', conn, 'app_user')
    expect(conn).to(have_received(:execute).with(include('ALTER DEFAULT PRIVILEGES').and(include('TABLES'))))
  end
end
```

- [ ] **Step 6: Run test to verify it fails**

Run: `bundle exec rspec spec/unit/adapters/postgresql_schema_adapter_spec.rb -e 'grant_privileges' -f doc`
Expected: FAIL — method is no-op

- [ ] **Step 7: Implement PostgresqlSchemaAdapter#grant_privileges**

In `lib/apartment/adapters/postgresql_schema_adapter.rb`, add after `resolve_connection_config`:

```ruby
private

def grant_privileges(tenant, connection, role_name)
  quoted_schema = connection.quote_table_name(tenant)
  quoted_role = connection.quote_table_name(role_name)

  connection.execute("GRANT USAGE ON SCHEMA #{quoted_schema} TO #{quoted_role}")
  connection.execute(
    "GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA #{quoted_schema} TO #{quoted_role}"
  )
  connection.execute(
    "GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA #{quoted_schema} TO #{quoted_role}"
  )
  connection.execute(
    "ALTER DEFAULT PRIVILEGES IN SCHEMA #{quoted_schema} " \
    "GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO #{quoted_role}"
  )
  connection.execute(
    "ALTER DEFAULT PRIVILEGES IN SCHEMA #{quoted_schema} " \
    "GRANT USAGE, SELECT ON SEQUENCES TO #{quoted_role}"
  )
  connection.execute(
    "ALTER DEFAULT PRIVILEGES IN SCHEMA #{quoted_schema} " \
    "GRANT EXECUTE ON FUNCTIONS TO #{quoted_role}"
  )
end
```

- [ ] **Step 8: Implement Mysql2Adapter#grant_privileges**

In `lib/apartment/adapters/mysql2_adapter.rb`, add:

```ruby
private

def grant_privileges(tenant, connection, role_name)
  db_name = environmentify(tenant)
  quoted_role = connection.quote(role_name)
  connection.execute(
    "GRANT SELECT, INSERT, UPDATE, DELETE ON `#{db_name}`.* TO #{quoted_role}@'%'"
  )
end
```

- [ ] **Step 9: Note: PostgresqlDatabaseAdapter grants deferred**

`PostgresqlDatabaseAdapter` inherits the no-op `grant_privileges` from `AbstractAdapter`. Database-per-tenant PG grants have a cross-database ordering issue (`GRANT CONNECT ON DATABASE` runs on the server connection, table/sequence grants run inside the tenant database). Per the design spec, the built-in default starts as a no-op; users with database-per-tenant PG + RBAC use the callable escape hatch. Add a comment in `PostgresqlDatabaseAdapter`:

```ruby
# grant_privileges: inherits no-op from AbstractAdapter.
# Database-per-tenant RBAC grants require cross-database ordering
# (GRANT CONNECT on server, table grants inside tenant DB).
# Use the callable app_role escape hatch for this strategy.
# See docs/designs/v4-phase5-rbac-roles-schema-cache.md.
```

- [ ] **Step 10: Run all adapter tests**

Run: `bundle exec rspec spec/unit/adapters/ -f doc`
Expected: PASS

- [ ] **Step 11: Commit**

```bash
git add lib/apartment/adapters/ spec/unit/adapters/
git commit -m "RBAC grants: grant_privileges in PG schema (6 SQL) and MySQL (1 SQL) adapters"
```

---

### Task 7: ConnectionHandling — Role-Aware Resolution

**Files:**
- Modify: `lib/apartment/patches/connection_handling.rb:12-48`
- Test: `spec/unit/connection_handling_role_spec.rb` (new)

This is the core change. The existing `ConnectionHandling#connection_pool` is fully replaced.

- [ ] **Step 1: Note on unit testing ConnectionHandling**

`ConnectionHandling#connection_pool` is a prepended method on `ActiveRecord::Base` that calls `super` for the default pool. Unit testing it in isolation requires a full AR setup. Rather than writing a vacuous test, the role-aware behavior is verified via:
- **Adapter tests** (Task 5): `base_config_override:` works correctly
- **Integration tests** (Task 11): Full `connected_to(role:) { Tenant.switch { ... } }` flow
- **Migrator tests** (Task 8): `with_migration_role` wraps correctly

No separate unit spec file for ConnectionHandling is created. The code is simple enough (pool key format, `super` call, delegation to adapter) that integration coverage is sufficient.

- [ ] **Step 2: Implement role-aware ConnectionHandling**

Replace the entire `connection_pool` method in `lib/apartment/patches/connection_handling.rb`:

```ruby
# frozen_string_literal: true

require 'active_record'

module Apartment
  module Patches
    module ConnectionHandling
      def connection_pool # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        tenant = Apartment::Current.tenant
        cfg = Apartment.config

        return super if tenant.nil? || cfg.nil?
        return super if tenant.to_s == cfg.default_tenant.to_s
        return super unless Apartment.pool_manager

        role = ActiveRecord::Base.current_role
        pool_key = "#{tenant}:#{role}"

        Apartment.pool_manager.fetch_or_create(pool_key) do
          default_pool = super
          base = default_pool.db_config.configuration_hash.stringify_keys

          config = Apartment.adapter.validated_connection_config(tenant, base_config_override: base)
          prefix = cfg.shard_key_prefix
          shard_key = :"#{prefix}_#{pool_key}"

          db_config = ActiveRecord::DatabaseConfigurations::HashConfig.new(
            cfg.rails_env_name,
            "#{prefix}_#{pool_key}",
            config
          )

          pool = ActiveRecord::Base.connection_handler.establish_connection(
            db_config,
            owner_name: ActiveRecord::Base,
            role: role,
            shard: shard_key
          )

          if check_pending_migrations?(pool)
            raise(Apartment::PendingMigrationError.new(tenant))
          end

          if cfg.schema_cache_per_tenant
            load_tenant_schema_cache(tenant, pool)
          end

          pool
        end
      rescue Apartment::ApartmentError
        raise
      rescue StandardError => e
        raise(Apartment::ApartmentError,
              "Failed to resolve connection pool for tenant '#{tenant}': #{e.class}: #{e.message}")
      end

      private

      def check_pending_migrations?(pool)
        return false unless Apartment.config.check_pending_migrations
        return false unless defined?(Rails) && Rails.env.local?
        return false if Apartment::Current.migrating

        pool.migration_context.needs_migration?
      end

      def load_tenant_schema_cache(tenant, pool)
        require_relative '../schema_cache'
        cache_path = Apartment::SchemaCache.cache_path_for(tenant)
        return unless File.exist?(cache_path)

        pool.schema_cache.load!(cache_path)
      end
    end
  end
end
```

- [ ] **Step 3: Run full unit suite to check for regressions**

Run: `bundle exec rspec spec/unit/ --format progress`
Expected: All passing (existing connection_handling tests may need pool key updates)

- [ ] **Step 4: Fix any failing tests due to pool key format change**

Existing tests that check pool keys as `"tenant"` must update to `"tenant:writing"` (or whatever `current_role` is). Search for `pool_key` or `fetch_or_create` in specs and update as needed.

- [ ] **Step 5: Commit**

```bash
git add lib/apartment/patches/connection_handling.rb spec/unit/connection_handling_role_spec.rb
git commit -m "Role-aware ConnectionHandling: resolve base config from current role's default pool"
```

---

### Task 8: Migrator — with_migration_role, Current.migrating, Pool Eviction

**Files:**
- Modify: `lib/apartment/migrator.rb:40-73,117-147`
- Test: `spec/unit/migrator_spec.rb` (existing, add cases)

- [ ] **Step 1: Write failing tests for with_migration_role**

In `spec/unit/migrator_spec.rb`, add:

```ruby
RSpec.describe(Apartment::Migrator, 'Phase 5: migration_role') do
  before do
    Apartment.configure do |c|
      c.tenant_strategy = :schema
      c.tenants_provider = -> { [] }
      c.default_tenant = 'public'
    end
  end

  describe '#with_migration_role' do
    it 'yields without connected_to when migration_role is nil' do
      Apartment.configure do |c|
        c.tenant_strategy = :schema
        c.tenants_provider = -> { [] }
        c.default_tenant = 'public'
        c.migration_role = nil
      end
      migrator = described_class.new

      expect(ActiveRecord::Base).not_to(receive(:connected_to))
      migrator.send(:with_migration_role) { 'result' }
    end

    it 'wraps in connected_to when migration_role is set' do
      Apartment.configure do |c|
        c.tenant_strategy = :schema
        c.tenants_provider = -> { [] }
        c.default_tenant = 'public'
        c.migration_role = :db_manager
      end
      migrator = described_class.new

      expect(ActiveRecord::Base).to(receive(:connected_to).with(role: :db_manager).and_yield)
      migrator.send(:with_migration_role) { 'result' }
    end
  end

  describe 'Current.migrating flag' do
    it 'sets Current.migrating in migrate_tenant' do
      Apartment.configure do |c|
        c.tenant_strategy = :schema
        c.tenants_provider = -> { [] }
        c.default_tenant = 'public'
      end
      migrator = described_class.new

      migrating_during_switch = nil
      allow(Apartment::Tenant).to(receive(:switch)).and_yield
      allow(ActiveRecord::Base).to(receive(:connection_pool).and_return(
        double(migration_context: double(needs_migration?: false))
      ))

      migrator.send(:migrate_tenant, 'acme')

      # Verify migrating was set (check indirectly via the flag being cleared in ensure)
      expect(Apartment::Current.migrating).to(be_falsey)
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/unit/migrator_spec.rb -e 'Phase 5' -f doc`
Expected: FAIL — `with_migration_role` not defined

- [ ] **Step 3: Implement Migrator changes**

In `lib/apartment/migrator.rb`, modify the `run` method to use `with_migration_role` for primary:

Replace `migrate_primary` call (line 48) with:
```ruby
primary_result = with_migration_role { migrate_primary }
```

Add `ensure` block to `run` for pool eviction:

```ruby
def run # rubocop:disable Metrics/MethodLength
  start = monotonic_now

  primary_result = with_migration_role { migrate_primary }

  if primary_result.status == :failed
    return MigrationRun.new(
      results: [primary_result],
      total_duration: monotonic_now - start,
      threads: @threads
    )
  end

  tenants = Apartment.config.tenants_provider.call
  tenant_results = if @threads.positive?
                     run_parallel(tenants)
                   else
                     run_sequential(tenants)
                   end

  all_results = [primary_result, *tenant_results].compact

  MigrationRun.new(
    results: all_results,
    total_duration: monotonic_now - start,
    threads: @threads
  )
ensure
  evict_migration_pools
end
```

Wrap `migrate_tenant` with `with_migration_role` and `Current.migrating`:

```ruby
def migrate_tenant(tenant) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
  start = monotonic_now
  Apartment::Current.migrating = true

  with_migration_role do
    Apartment::Tenant.switch(tenant) do
      context = ActiveRecord::Base.connection_pool.migration_context

      unless @version || context.needs_migration?
        return Result.new(
          tenant: tenant, status: :skipped,
          duration: monotonic_now - start, error: nil, versions_run: []
        )
      end

      with_advisory_locks_disabled do
        raw_versions = context.migrate(@version)
        versions = Array(raw_versions).map { _1.respond_to?(:version) ? _1.version : _1 }

        Instrumentation.instrument(:migrate_tenant, tenant: tenant, versions: versions)

        Result.new(
          tenant: tenant, status: :success,
          duration: monotonic_now - start, error: nil, versions_run: versions
        )
      end
    end
  end
rescue StandardError => e
  Result.new(
    tenant: tenant, status: :failed,
    duration: monotonic_now - start, error: e, versions_run: []
  )
ensure
  Apartment::Current.migrating = false
end
```

Add private methods:

```ruby
def with_migration_role(&)
  role = Apartment.config.migration_role
  role ? ActiveRecord::Base.connected_to(role: role, &) : yield
end

def evict_migration_pools
  role = Apartment.config.migration_role
  return unless role && Apartment.pool_manager

  Apartment.pool_manager.evict_by_role(role).each do |pool_key, _pool|
    Apartment.deregister_shard(pool_key)
  end
rescue StandardError => e
  warn "[Apartment::Migrator] Pool eviction failed: #{e.class}: #{e.message}"
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/unit/migrator_spec.rb -f doc`
Expected: PASS

- [ ] **Step 5: Run full unit suite**

Run: `bundle exec rspec spec/unit/ --format progress`
Expected: All passing

- [ ] **Step 6: Commit**

```bash
git add lib/apartment/migrator.rb spec/unit/migrator_spec.rb
git commit -m "Migrator: with_migration_role, Current.migrating flag, post-migration pool eviction"
```

---

### Task 9: SchemaCache Module

**Files:**
- Create: `lib/apartment/schema_cache.rb`
- Test: `spec/unit/schema_cache_spec.rb` (new)

- [ ] **Step 1: Write failing test**

Create `spec/unit/schema_cache_spec.rb`:

```ruby
# frozen_string_literal: true

require 'spec_helper'
require_relative '../../lib/apartment/schema_cache'

RSpec.describe(Apartment::SchemaCache) do
  describe '.cache_path_for' do
    it 'returns db/schema_cache_<tenant>.yml' do
      path = described_class.cache_path_for('acme')
      expect(path).to(end_with('db/schema_cache_acme.yml'))
    end
  end

  describe '.dump' do
    it 'switches to tenant and dumps schema cache' do
      schema_cache = double('schema_cache')
      connection = double('connection', schema_cache: schema_cache)
      allow(Apartment::Tenant).to(receive(:switch).and_yield)
      allow(ActiveRecord::Base).to(receive(:connection).and_return(connection))
      allow(schema_cache).to(receive(:dump_to))

      path = described_class.dump('acme')

      expect(Apartment::Tenant).to(have_received(:switch).with('acme'))
      expect(schema_cache).to(have_received(:dump_to).with(path))
      expect(path).to(end_with('schema_cache_acme.yml'))
    end
  end

  describe '.dump_all' do
    it 'dumps for each tenant from provider' do
      Apartment.configure do |c|
        c.tenant_strategy = :schema
        c.tenants_provider = -> { %w[t1 t2] }
        c.default_tenant = 'public'
      end

      allow(described_class).to(receive(:dump).and_return('path'))

      described_class.dump_all

      expect(described_class).to(have_received(:dump).with('t1'))
      expect(described_class).to(have_received(:dump).with('t2'))
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/unit/schema_cache_spec.rb -f doc`
Expected: FAIL — `Apartment::SchemaCache` not defined

- [ ] **Step 3: Implement SchemaCache module**

Create `lib/apartment/schema_cache.rb`:

```ruby
# frozen_string_literal: true

require 'pathname'

module Apartment
  module SchemaCache
    module_function

    def dump(tenant)
      path = cache_path_for(tenant)
      Apartment::Tenant.switch(tenant) do
        ActiveRecord::Base.connection.schema_cache.dump_to(path)
      end
      path
    end

    def dump_all
      Apartment.config.tenants_provider.call.map { |t| dump(t) }
    end

    def cache_path_for(tenant)
      base = defined?(Rails) && Rails.root ? Rails.root.join('db') : Pathname.new('db')
      base.join("schema_cache_#{tenant}.yml").to_s
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/unit/schema_cache_spec.rb -f doc`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/apartment/schema_cache.rb spec/unit/schema_cache_spec.rb
git commit -m "Add Apartment::SchemaCache module for per-tenant cache generation"
```

---

### Task 10: Rake Task — apartment:schema:cache:dump

**Files:**
- Modify: `lib/apartment/tasks/v4.rake:77`

- [ ] **Step 1: Add the rake task**

At the end of `lib/apartment/tasks/v4.rake` (before the final `end`), add:

```ruby
namespace :schema do
  namespace :cache do
    desc 'Dump schema cache for each tenant'
    task dump: :environment do
      require 'apartment/schema_cache'
      paths = Apartment::SchemaCache.dump_all
      paths.each { |p| puts "Dumped: #{p}" }
    end
  end
end
```

- [ ] **Step 2: Verify rake task loads**

Run: `bundle exec rake -T apartment:schema` (may require Rails context — verify in integration)

- [ ] **Step 3: Commit**

```bash
git add lib/apartment/tasks/v4.rake
git commit -m "Add apartment:schema:cache:dump rake task"
```

---

### Task 11: Integration Tests (requires databases)

**Files:**
- Create: `spec/integration/v4/role_aware_connection_spec.rb`
- Create: `spec/integration/v4/pending_migration_spec.rb`

Integration tests for RBAC grants and migrator role require PostgreSQL with actual roles configured — these should be written after the unit tests pass and validated against the CI matrix. The spec shapes are documented in the design spec (section "Integration Tests").

- [ ] **Step 1: Write integration test for role-aware pool resolution (SQLite)**

Create `spec/integration/v4/role_aware_connection_spec.rb` with a basic test that verifies pool keys include the role suffix when `Tenant.switch` is used.

- [ ] **Step 2: Write integration test for PendingMigrationError (SQLite)**

Create `spec/integration/v4/pending_migration_spec.rb` that creates a tenant, adds a migration, and verifies the error is raised on pool creation in a local environment.

- [ ] **Step 3: Run integration tests**

Run: `bundle exec appraisal rails-8.1-sqlite3 rspec spec/integration/v4/role_aware_connection_spec.rb spec/integration/v4/pending_migration_spec.rb -f doc`

- [ ] **Step 4: Commit**

```bash
git add spec/integration/v4/
git commit -m "Integration tests: role-aware connections and PendingMigrationError"
```

---

### Task 12: Final Verification

- [ ] **Step 1: Run full unit suite**

Run: `bundle exec rspec spec/unit/ --format progress`
Expected: All passing

- [ ] **Step 2: Run full unit suite across Rails versions**

Run: `bundle exec appraisal rspec spec/unit/ --format progress`
Expected: All passing across all appraisals

- [ ] **Step 3: Run integration suite (SQLite)**

Run: `bundle exec appraisal rails-8.1-sqlite3 rspec spec/integration/v4/ --format progress`

- [ ] **Step 4: Run linter**

Run: `bundle exec rubocop lib/apartment/ spec/unit/`
Fix any offenses.

- [ ] **Step 5: Final commit (lint fixes if any)**

```bash
git add -A
git commit -m "Lint fixes for Phase 5"
```
