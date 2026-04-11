# TestFixtures Compatibility Patch — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent `ArgumentError` from Rails' `setup_shared_connection_pool` when apartment tenant pools exist under non-writing roles.

**Architecture:** Auto-wire a prepend on `ActiveRecord::TestFixtures` (via Railtie + `on_load(:active_record_fixtures)`) that deregisters apartment's tenant pools before Rails' fixture setup iterates shards. A guard ivar prevents re-entry from the `!connection.active_record` notification subscriber.

**Tech Stack:** Ruby, Rails ActiveRecord TestFixtures, RSpec

**Design spec:** `docs/designs/v4-test-fixtures-compatibility.md`

---

## File Map

| Action | File | Responsibility |
|--------|------|----------------|
| Create | `lib/apartment/test_fixtures.rb` | `Apartment::TestFixtures` module: overrides `setup_shared_connection_pool` and `teardown_shared_connection_pool` |
| Modify | `lib/apartment/config.rb` | Add `test_fixture_cleanup` attribute (default `true`) |
| Modify | `lib/apartment/railtie.rb` | Wire `on_load(:active_record_fixtures)` hook in test env |
| Create | `spec/unit/test_fixtures_spec.rb` | Unit tests for the patch |

---

### Task 1: Add `test_fixture_cleanup` config attribute

**Files:**
- Modify: `lib/apartment/config.rb:17` (attr_accessor line), `:28-54` (initialize), `:112-178` (validate!)
- Test: `spec/unit/config_spec.rb` (existing)

- [ ] **Step 1: Write the failing test**

Add to `spec/unit/config_spec.rb`, inside the main describe block. Find the existing pattern for boolean config attributes (e.g., `check_pending_migrations`) and follow it.

```ruby
describe 'test_fixture_cleanup' do
  it 'defaults to true' do
    Apartment.configure do |config|
      config.tenant_strategy = :schema
      config.tenants_provider = -> { [] }
    end
    expect(Apartment.config.test_fixture_cleanup).to be(true)
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bundle exec rspec spec/unit/config_spec.rb -e 'test_fixture_cleanup'`
Expected: FAIL — `undefined method 'test_fixture_cleanup'`

- [ ] **Step 3: Add the attribute**

In `lib/apartment/config.rb`:

1. Add `:test_fixture_cleanup` to the `attr_accessor` list on line 17 (after `:force_separate_pinned_pool`).

2. Add `@test_fixture_cleanup = true` in `initialize` (after `@force_separate_pinned_pool = false`, around line 54).

No validation needed — boolean with a safe default; no freeze needed.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bundle exec rspec spec/unit/config_spec.rb -e 'test_fixture_cleanup'`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/apartment/config.rb spec/unit/config_spec.rb
git commit -m "Add test_fixture_cleanup config attribute (default: true)"
```

---

### Task 2: Create `Apartment::TestFixtures` module

**Files:**
- Create: `lib/apartment/test_fixtures.rb`
- Test: `spec/unit/test_fixtures_spec.rb`

- [ ] **Step 1: Write the failing tests**

Create `spec/unit/test_fixtures_spec.rb`. This test requires real ActiveRecord (same pattern as `spec/unit/patches/connection_handling_spec.rb`). It simulates the scenario: register a tenant pool under `:reading` only, then exercise `setup_shared_connection_pool`.

```ruby
# frozen_string_literal: true

require 'spec_helper'

# This spec requires real ActiveRecord + sqlite3 gem.
# Run via any sqlite3 appraisal, e.g.: bundle exec appraisal rails-8.1-sqlite3 rspec spec/unit/test_fixtures_spec.rb
# Skips gracefully when sqlite3 is not available.
FIXTURES_AR_AVAILABLE = begin
  require('active_record')
  if ActiveRecord::Base.respond_to?(:establish_connection)
    ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
    require_relative('../../lib/apartment/patches/connection_handling')
    ActiveRecord::Base.singleton_class.prepend(Apartment::Patches::ConnectionHandling)
    true
  else
    warn '[test_fixtures_spec] Skipping: AR stub loaded (no establish_connection)'
    false
  end
rescue LoadError => e
  warn "[test_fixtures_spec] Skipping: #{e.message}"
  false
end

RSpec.describe('Apartment::TestFixtures') do
  before do
    skip 'requires real ActiveRecord with sqlite3 gem (run via appraisal)' unless FIXTURES_AR_AVAILABLE
    Apartment.configure do |config|
      config.tenant_strategy = :schema
      config.tenants_provider = -> { %w[acme] }
      config.default_tenant = 'public'
      config.check_pending_migrations = false
    end
    Apartment.adapter = mock_adapter
  end

  after do
    Apartment.clear_config
    Apartment::Current.reset
  end

  let(:mock_adapter) do
    double('AbstractAdapter',
           validated_connection_config: { 'adapter' => 'sqlite3', 'database' => ':memory:' },
           shared_pinned_connection?: false)
  end

  # Helper: register a tenant pool under a specific role by simulating
  # what ConnectionHandling#connection_pool does.
  def register_tenant_pool(tenant, role)
    pool_key = "#{tenant}:#{role}"
    prefix = Apartment.config.shard_key_prefix
    shard_key = :"#{prefix}_#{pool_key}"
    config = { 'adapter' => 'sqlite3', 'database' => ':memory:' }
    db_config = ActiveRecord::DatabaseConfigurations::HashConfig.new('test', "#{prefix}_#{pool_key}", config)
    ActiveRecord::Base.connection_handler.establish_connection(
      db_config, owner_name: ActiveRecord::Base, role: role, shard: shard_key
    )
    Apartment.pool_manager.fetch_or_create(pool_key) do |_key|
      ActiveRecord::Base.connection_handler.retrieve_connection_pool(
        'ActiveRecord::Base', role: role, shard: shard_key
      )
    end
  end

  # Minimal fixture host: includes TestFixtures so setup_shared_connection_pool is available.
  let(:fixture_host_class) do
    Class.new do
      include ActiveRecord::TestFixtures

      # TestFixtures expects @saved_pool_configs to exist (initialized in setup_fixtures)
      def initialize
        @saved_pool_configs = Hash.new { |hash, key| hash[key] = {} }
      end

      # Expose private methods for testing
      public :setup_shared_connection_pool, :teardown_shared_connection_pool
    end
  end

  describe 'without the patch' do
    it 'raises ArgumentError when a tenant pool exists under :reading only' do
      register_tenant_pool('acme', :reading)
      host = fixture_host_class.new
      expect { host.setup_shared_connection_pool }.to raise_error(ArgumentError, /pool_config.*nil/)
    end
  end

  describe 'with the patch' do
    let(:patched_host_class) do
      require_relative('../../lib/apartment/test_fixtures')
      klass = fixture_host_class
      klass.prepend(Apartment::TestFixtures)
      klass
    end

    it 'does not raise when a tenant pool exists under :reading only' do
      register_tenant_pool('acme', :reading)
      host = patched_host_class.new
      expect { host.setup_shared_connection_pool }.not_to raise_error
    end

    it 'clears apartment pools from the ConnectionHandler' do
      register_tenant_pool('acme', :reading)
      host = patched_host_class.new
      host.setup_shared_connection_pool

      shard_key = :"#{Apartment.config.shard_key_prefix}_acme:reading"
      pool = ActiveRecord::Base.connection_handler.retrieve_connection_pool(
        'ActiveRecord::Base', role: :reading, shard: shard_key
      )
      expect(pool).to be_nil
    end

    it 'clears the pool manager' do
      register_tenant_pool('acme', :reading)
      host = patched_host_class.new
      host.setup_shared_connection_pool

      expect(Apartment.pool_manager.stats[:total_pools]).to eq(0)
    end

    it 'does not clean up on re-entrant calls (subscriber path)' do
      host = patched_host_class.new

      # First call: cleans up
      host.setup_shared_connection_pool
      expect(host.instance_variable_get(:@apartment_fixtures_cleaned)).to be(true)

      # Register a pool AFTER first cleanup (simulates mid-example pool creation)
      register_tenant_pool('acme', :writing)
      pool_count_before = Apartment.pool_manager.stats[:total_pools]

      # Second call (re-entry from subscriber): should NOT clean up
      host.setup_shared_connection_pool
      expect(Apartment.pool_manager.stats[:total_pools]).to eq(pool_count_before)
    end

    it 'resets the guard on teardown' do
      host = patched_host_class.new
      host.setup_shared_connection_pool
      expect(host.instance_variable_get(:@apartment_fixtures_cleaned)).to be(true)

      host.teardown_shared_connection_pool
      expect(host.instance_variable_get(:@apartment_fixtures_cleaned)).to be(false)
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec appraisal rails-8.1-sqlite3 rspec spec/unit/test_fixtures_spec.rb`
Expected: The "without the patch" test should PASS (it confirms the bug exists — `ArgumentError` is raised). The "with the patch" tests should FAIL with `LoadError` because `lib/apartment/test_fixtures.rb` doesn't exist yet.

- [ ] **Step 3: Create the module**

Create `lib/apartment/test_fixtures.rb`:

```ruby
# frozen_string_literal: true

module Apartment
  # Prepended on the class that includes ActiveRecord::TestFixtures
  # (e.g., ActiveSupport::TestCase or the RSpec fixture host).
  #
  # Rails' setup_shared_connection_pool iterates all shards registered in
  # the ConnectionHandler and assumes every shard has a :writing pool_config.
  # Apartment's role-specific tenant shards violate this invariant, causing
  # ArgumentError. This module deregisters apartment pools before the fixture
  # machinery iterates them. Pools rebuild lazily on next connection_pool call.
  #
  # A guard ivar (@apartment_fixtures_cleaned) prevents re-entry: the
  # !connection.active_record notification subscriber in
  # setup_transactional_fixtures calls setup_shared_connection_pool again
  # when new pools appear mid-example.
  module TestFixtures
    private

    def setup_shared_connection_pool
      unless @apartment_fixtures_cleaned
        @apartment_fixtures_cleaned = true
        if Apartment.pool_manager
          Apartment.send(:deregister_all_tenant_pools)
          Apartment.pool_manager.clear
          Apartment::Current.reset
        end
      end
      super
    end

    def teardown_shared_connection_pool
      @apartment_fixtures_cleaned = false
      super
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bundle exec appraisal rails-8.1-sqlite3 rspec spec/unit/test_fixtures_spec.rb`
Expected: All tests PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/apartment/test_fixtures.rb spec/unit/test_fixtures_spec.rb
git commit -m "Add Apartment::TestFixtures to deregister tenant pools before fixture setup"
```

---

### Task 3: Wire the Railtie hook

**Files:**
- Modify: `lib/apartment/railtie.rb:50` (before the `rake_tasks` block)
- Test: `spec/unit/railtie_spec.rb` (existing, if railtie specs exist) or manual verification

- [ ] **Step 1: Check for existing railtie specs**

Run: `find spec -name '*railtie*' -type f` to see if there are existing railtie unit tests. If not, this task will be verified by the integration-level unit test in Task 2 (which manually prepends, covering the module behavior) and by downstream app testing.

- [ ] **Step 2: Add the on_load hook to the Railtie**

In `lib/apartment/railtie.rb`, add the following block after the `initializer 'apartment.middleware'` block and before the `rake_tasks` block (before line 51):

```ruby
    # In test environments, clean up apartment's tenant pools before Rails'
    # fixture setup iterates shards. See docs/designs/v4-test-fixtures-compatibility.md.
    if Rails.env.test?
      ActiveSupport.on_load(:active_record_fixtures) do
        if Apartment.config&.test_fixture_cleanup
          require 'apartment/test_fixtures'
          prepend Apartment::TestFixtures
        end
      end
    end
```

- [ ] **Step 3: Verify no existing tests break**

Run: `bundle exec appraisal rails-8.1-sqlite3 rspec spec/unit/`
Expected: All existing unit tests PASS. The `on_load` hook won't fire during unit tests (no fixture support loaded in the gem's RSpec suite), so this is a no-op in the test run.

- [ ] **Step 4: Commit**

```bash
git add lib/apartment/railtie.rb
git commit -m "Wire TestFixtures cleanup via Railtie on_load(:active_record_fixtures)"
```

---

### Task 4: Run full test suite and verify

**Files:** None (verification only)

- [ ] **Step 1: Run unit tests across all appraisals**

Run: `bundle exec appraisal rspec spec/unit/`
Expected: All tests PASS across all Rails versions.

- [ ] **Step 2: Run rubocop on changed files**

Run: `bundle exec rubocop lib/apartment/test_fixtures.rb lib/apartment/config.rb lib/apartment/railtie.rb spec/unit/test_fixtures_spec.rb`
Expected: No offenses. Fix any that arise.

- [ ] **Step 3: Run the specific test_fixtures_spec across appraisals**

Run: `bundle exec appraisal rspec spec/unit/test_fixtures_spec.rb`
Expected: PASS on all appraisals (tests skip gracefully when sqlite3 is unavailable for that appraisal).

- [ ] **Step 4: Final commit if rubocop required changes**

Only if step 2 produced fixes:
```bash
git add -A
git commit -m "Fix rubocop offenses in test_fixtures patch"
```
