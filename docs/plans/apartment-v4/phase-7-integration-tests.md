# Phase 7: Integration & Stress Tests — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fill remaining integration test gaps: fiber safety, memory stability, CLI integration, and thread safety hardening.

**Architecture:** Three new spec files in `spec/integration/v4/` (flat structure, no subdirectories) plus two additive `it` blocks in the existing `stress_spec.rb`. One drive-by fix in `coverage_gaps_spec.rb`. All specs use the existing `V4IntegrationHelper` setup pattern.

**Tech Stack:** RSpec, concurrent-ruby (`CyclicBarrier`, `Map`, `Array`), ActiveRecord, Thor CLI classes.

---

### Task 1: Create `fiber_safety_spec.rb`

**Files:**
- Create: `spec/integration/v4/fiber_safety_spec.rb`

- [ ] **Step 1: Write the spec file with all fiber safety tests**

```ruby
# frozen_string_literal: true

require 'spec_helper'
require_relative 'support'

RSpec.describe('v4 Fiber safety integration', :integration,
               skip: (V4_INTEGRATION_AVAILABLE ? false : 'requires ActiveRecord + database gem')) do
  include V4IntegrationHelper

  let(:tmp_dir) { Dir.mktmpdir('apartment_fiber') }
  let(:tenants) { %w[fiber_a fiber_b] }

  before do
    V4IntegrationHelper.ensure_test_database! unless V4IntegrationHelper.sqlite?
    config = V4IntegrationHelper.establish_default_connection!(tmp_dir: tmp_dir)
    V4IntegrationHelper.create_test_table!

    stub_const('Widget', Class.new(ActiveRecord::Base) { self.table_name = 'widgets' })

    Apartment.configure do |c|
      c.tenant_strategy = V4IntegrationHelper.tenant_strategy
      c.tenants_provider = -> { tenants }
      c.default_tenant = V4IntegrationHelper.default_tenant
      c.check_pending_migrations = false
    end

    Apartment.adapter = V4IntegrationHelper.build_adapter(config)
    Apartment.activate!

    tenants.each do |t|
      Apartment.adapter.create(t)
      Apartment::Tenant.switch(t) do
        V4IntegrationHelper.create_test_table!('widgets', connection: ActiveRecord::Base.connection)
      end
    end
  end

  after do
    V4IntegrationHelper.cleanup_tenants!(tenants, Apartment.adapter)
    Apartment.clear_config
    Apartment::Current.reset
    if V4IntegrationHelper.sqlite?
      ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
      FileUtils.rm_rf(tmp_dir)
    end
  end

  it 'isolates tenant state across fibers' do
    Apartment::Tenant.switch('fiber_a') do
      child_tenant = Fiber.new do
        Apartment::Tenant.switch('fiber_b') do
          Fiber.yield Apartment::Tenant.current
        end
      end

      child_result = child_tenant.resume
      expect(child_result).to(eq('fiber_b'))
      expect(Apartment::Tenant.current).to(eq('fiber_a'))
      expect(Apartment::Current.tenant).to(eq('fiber_a'))
    end
  end

  it 'preserves tenant across Fiber.yield/resume cycles' do
    fiber = Fiber.new do
      Apartment::Tenant.switch('fiber_a') do
        Fiber.yield :switched
        Apartment::Tenant.current
      end
    end

    expect(fiber.resume).to(eq(:switched))
    expect(fiber.resume).to(eq('fiber_a'))
  end

  it 'outer switch block unaffected by inner fiber switching' do
    Apartment::Tenant.switch('fiber_a') do
      Widget.create!(name: 'outer')

      fiber = Fiber.new do
        Apartment::Tenant.switch('fiber_b') do
          Widget.create!(name: 'inner')
          Apartment::Tenant.current
        end
      end

      inner_tenant = fiber.resume
      expect(inner_tenant).to(eq('fiber_b'))
      expect(Apartment::Tenant.current).to(eq('fiber_a'))
      expect(Widget.count).to(eq(1))
      expect(Widget.first.name).to(eq('outer'))
    end

    Apartment::Tenant.switch('fiber_b') do
      expect(Widget.count).to(eq(1))
      expect(Widget.first.name).to(eq('inner'))
    end
  end

  context 'Fiber.scheduler integration',
          skip: (RUBY_VERSION < '3.1' ? 'requires Ruby 3.1+ for Fiber.scheduler' : false) do
    it 'tenant state does not leak across scheduled fibers' do
      results = []
      mutex = Mutex.new

      scheduler = Fiber::Scheduler.new if defined?(Fiber::Scheduler)
      skip 'no built-in Fiber::Scheduler available' unless scheduler

      Fiber.set_scheduler(scheduler)

      Fiber.schedule do
        Apartment::Tenant.switch('fiber_a') do
          sleep(0.01) # yield to scheduler
          mutex.synchronize { results << { fiber: :a, tenant: Apartment::Tenant.current } }
        end
      end

      Fiber.schedule do
        Apartment::Tenant.switch('fiber_b') do
          sleep(0.01) # yield to scheduler
          mutex.synchronize { results << { fiber: :b, tenant: Apartment::Tenant.current } }
        end
      end

      Fiber.scheduler.close
      Fiber.set_scheduler(nil)

      a_result = results.find { |r| r[:fiber] == :a }
      b_result = results.find { |r| r[:fiber] == :b }

      expect(a_result).not_to(be_nil, 'Fiber A did not produce a result')
      expect(b_result).not_to(be_nil, 'Fiber B did not produce a result')
      expect(a_result[:tenant]).to(eq('fiber_a'))
      expect(b_result[:tenant]).to(eq('fiber_b'))
    end
  end

  context 'load_async integration',
          skip: (ActiveRecord::Relation.method_defined?(:load_async) ? false : 'requires load_async support') do
    it 'async relation resolves against the correct tenant pool' do
      Apartment::Tenant.switch('fiber_a') do
        Widget.create!(name: 'async_test')
      end

      Apartment::Tenant.switch('fiber_a') do
        relation = Widget.where(name: 'async_test').load_async
        # Force resolution
        results = relation.to_a
        expect(results.size).to(eq(1))
        expect(results.first.name).to(eq('async_test'))
      end

      # Verify it didn't leak into fiber_b
      Apartment::Tenant.switch('fiber_b') do
        expect(Widget.where(name: 'async_test').count).to(eq(0))
      end
    end
  end
end
```

- [ ] **Step 2: Run the spec on SQLite to verify it passes**

Run: `bundle exec appraisal rails-8.1-sqlite3 rspec spec/integration/v4/fiber_safety_spec.rb --format documentation`

Expected: All non-skipped examples pass. The Fiber.scheduler test will likely skip (no built-in scheduler in MRI). The load_async test should pass if the Rails version supports it.

- [ ] **Step 3: Commit**

```bash
git add spec/integration/v4/fiber_safety_spec.rb
git commit -m "Add fiber safety integration spec

Proves CurrentAttributes isolates tenant state across fibers:
basic isolation, yield/resume cycles, nested switch blocks,
conditional Fiber.scheduler and load_async tests."
```

---

### Task 2: Create `memory_stability_spec.rb`

**Files:**
- Create: `spec/integration/v4/memory_stability_spec.rb`

- [ ] **Step 1: Write the spec file with all memory stability tests**

```ruby
# frozen_string_literal: true

require 'spec_helper'
require_relative 'support'

RSpec.describe('v4 Memory stability integration', :integration,
               skip: (V4_INTEGRATION_AVAILABLE ? false : 'requires ActiveRecord + database gem')) do
  include V4IntegrationHelper

  # ── Pool count stays bounded under max_total_connections ───────────
  context 'bounded pool count',
          skip: (V4IntegrationHelper.sqlite? ? 'SQLite pool-per-tenant less meaningful with single-writer lock' : false) do
    let(:tmp_dir) { Dir.mktmpdir('apartment_mem_bounded') }
    let(:tenants) { Array.new(20) { |i| "mem_bounded_#{i}" } }

    before do
      V4IntegrationHelper.ensure_test_database!
      config = V4IntegrationHelper.establish_default_connection!(tmp_dir: tmp_dir)
      V4IntegrationHelper.create_test_table!

      Apartment.configure do |c|
        c.tenant_strategy = V4IntegrationHelper.tenant_strategy
        c.tenants_provider = -> { tenants }
        c.default_tenant = V4IntegrationHelper.default_tenant
        c.pool_idle_timeout = 300
        c.max_total_connections = 5
        c.check_pending_migrations = false
      end

      Apartment.adapter = V4IntegrationHelper.build_adapter(config)
      Apartment.activate!

      tenants.each do |t|
        Apartment.adapter.create(t)
        Apartment::Tenant.switch(t) do
          V4IntegrationHelper.create_test_table!('widgets', connection: ActiveRecord::Base.connection)
        end
      end
    end

    after do
      V4IntegrationHelper.cleanup_tenants!(tenants, Apartment.adapter)
      Apartment.clear_config
      Apartment::Current.reset
    end

    it 'pool count stays within max_total_connections after reaper cycles' do
      stub_const('Widget', Class.new(ActiveRecord::Base) { self.table_name = 'widgets' })

      3.times do |cycle|
        tenants.each do |t|
          Apartment::Tenant.switch(t) do
            Widget.create!(name: "cycle_#{cycle}")
          end
        end

        Apartment.pool_reaper.run_cycle

        pool_count = Apartment.pool_manager.stats[:total_pools]
        expect(pool_count).to(be <= 5),
          "Cycle #{cycle}: expected <= 5 pools, got #{pool_count}"
      end
    end
  end

  # ── Repeated create/drop doesn't leak pools ────────────────────────
  context 'create/drop cycle',
          skip: (V4IntegrationHelper.sqlite? ? 'SQLite pool-per-tenant less meaningful with single-writer lock' : false) do
    let(:tmp_dir) { Dir.mktmpdir('apartment_mem_cycle') }

    before do
      V4IntegrationHelper.ensure_test_database!
      config = V4IntegrationHelper.establish_default_connection!(tmp_dir: tmp_dir)

      Apartment.configure do |c|
        c.tenant_strategy = V4IntegrationHelper.tenant_strategy
        c.tenants_provider = -> { [] }
        c.default_tenant = V4IntegrationHelper.default_tenant
        c.check_pending_migrations = false
      end

      Apartment.adapter = V4IntegrationHelper.build_adapter(config)
      Apartment.activate!
    end

    after do
      Apartment.clear_config
      Apartment::Current.reset
    end

    it 'pool count returns to baseline after 20 create/drop cycles' do
      baseline = Apartment.pool_manager.stats[:total_pools]

      20.times do |i|
        tenant = "ephemeral_#{i}"
        Apartment.adapter.create(tenant)
        Apartment::Tenant.switch(tenant) do
          ActiveRecord::Base.connection.execute('SELECT 1')
        end
        Apartment.adapter.drop(tenant)
      end

      final = Apartment.pool_manager.stats[:total_pools]
      expect(final).to(be <= baseline + 1),
        "Expected pool count near baseline #{baseline}, got #{final}"
    end
  end

  # ── Sustained switching without pool growth ─────────────────────────
  context 'sustained switching' do
    let(:tmp_dir) { Dir.mktmpdir('apartment_mem_sustained') }
    let(:tenants) { Array.new(5) { |i| "sustained_#{i}" } }

    before do
      V4IntegrationHelper.ensure_test_database! unless V4IntegrationHelper.sqlite?
      config = V4IntegrationHelper.establish_default_connection!(tmp_dir: tmp_dir)
      V4IntegrationHelper.create_test_table!

      Apartment.configure do |c|
        c.tenant_strategy = V4IntegrationHelper.tenant_strategy
        c.tenants_provider = -> { tenants }
        c.default_tenant = V4IntegrationHelper.default_tenant
        c.max_total_connections = 100
        c.check_pending_migrations = false
      end

      Apartment.adapter = V4IntegrationHelper.build_adapter(config)
      Apartment.activate!

      tenants.each do |t|
        Apartment.adapter.create(t)
        Apartment::Tenant.switch(t) do
          V4IntegrationHelper.create_test_table!('widgets', connection: ActiveRecord::Base.connection)
        end
      end
    end

    after do
      V4IntegrationHelper.cleanup_tenants!(tenants, Apartment.adapter)
      Apartment.clear_config
      Apartment::Current.reset
      if V4IntegrationHelper.sqlite?
        ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
        FileUtils.rm_rf(tmp_dir)
      end
    end

    it 'no phantom pools after 200 round-robin switches' do
      stub_const('Widget', Class.new(ActiveRecord::Base) { self.table_name = 'widgets' })

      # Prime all tenant pools
      tenants.each do |t|
        Apartment::Tenant.switch(t) { Widget.create!(name: 'prime') }
      end

      expected_pools = Apartment.pool_manager.stats[:total_pools]

      200.times do |i|
        tenant = tenants[i % tenants.size]
        Apartment::Tenant.switch(tenant) do
          ActiveRecord::Base.connection.execute('SELECT 1')
        end
      end

      final_pools = Apartment.pool_manager.stats[:total_pools]
      expect(final_pools).to(eq(expected_pools)),
        "Expected #{expected_pools} pools after 200 switches, got #{final_pools}"
    end
  end
end
```

- [ ] **Step 2: Run the spec on SQLite (sustained switching context) and PG (all contexts)**

Run: `bundle exec appraisal rails-8.1-sqlite3 rspec spec/integration/v4/memory_stability_spec.rb --format documentation`

Expected: The two PG/MySQL-only contexts skip on SQLite. The "sustained switching" context passes.

Run: `DATABASE_ENGINE=postgresql bundle exec appraisal rails-8.1-postgresql rspec spec/integration/v4/memory_stability_spec.rb --format documentation`

Expected: All 3 examples pass.

- [ ] **Step 3: Commit**

```bash
git add spec/integration/v4/memory_stability_spec.rb
git commit -m "Add memory stability integration spec

Proves pool count stays bounded under max_total_connections,
create/drop cycles don't leak pools, and sustained round-robin
switching doesn't create phantom pool entries."
```

---

### Task 3: Harden `stress_spec.rb` with two new `it` blocks

**Files:**
- Modify: `spec/integration/v4/stress_spec.rb:106` (insert before the closing `end` of `concurrent switching` context)

- [ ] **Step 1: Add the two new tests after line 106 in the `concurrent switching` context**

Insert the following two `it` blocks after `stress_spec.rb:106` (after the existing `concurrent pool creation` test, before the `end` that closes the `concurrent switching` context):

```ruby
    it 'each thread sees correct Tenant.current inside switch block' do
      barrier = Concurrent::CyclicBarrier.new(5)
      results = Concurrent::Map.new
      errors = Queue.new

      threads = tenants.map.with_index do |tenant, idx|
        Thread.new do
          barrier.wait
          Apartment::Tenant.switch(tenant) do
            results[idx] = {
              tenant_current: Apartment::Tenant.current,
              current_tenant: Apartment::Current.tenant,
            }
          end
        rescue StandardError => e
          errors << "Thread #{idx}: #{e.class}: #{e.message}"
        end
      end
      threads.each(&:join)

      collected_errors = []
      collected_errors << errors.pop until errors.empty?
      expect(collected_errors).to(be_empty)

      tenants.each_with_index do |tenant, idx|
        expect(results[idx]).not_to(be_nil, "Thread #{idx} produced no result")
        expect(results[idx][:tenant_current]).to(eq(tenant),
          "Thread #{idx}: Tenant.current was '#{results[idx][:tenant_current]}', expected '#{tenant}'")
        expect(results[idx][:current_tenant]).to(eq(tenant),
          "Thread #{idx}: Current.tenant was '#{results[idx][:current_tenant]}', expected '#{tenant}'")
      end
    end

    it 'cross-tenant connection checkout returns only own tenant data' do
      barrier = Concurrent::CyclicBarrier.new(2)
      results = Concurrent::Map.new
      errors = Queue.new

      %w[stress_0 stress_1].each_with_index do |tenant, idx|
        Thread.new do
          barrier.wait
          Apartment::Tenant.switch(tenant) do
            Widget.create!(name: "isolation_#{idx}")
            results[idx] = Widget.pluck(:name)
          end
        rescue StandardError => e
          errors << "Thread #{idx}: #{e.class}: #{e.message}"
        end
      end.each(&:join)

      collected_errors = []
      collected_errors << errors.pop until errors.empty?
      expect(collected_errors).to(be_empty)

      expect(results[0]).to(include('isolation_0'))
      expect(results[0]).not_to(include('isolation_1'),
        "Thread 0 (stress_0) read data from stress_1's pool")
      expect(results[1]).to(include('isolation_1'))
      expect(results[1]).not_to(include('isolation_0'),
        "Thread 1 (stress_1) read data from stress_0's pool")
    end
```

The insertion point is between line 106 (`end` closing the `concurrent pool creation` test) and line 107 (`end` closing the `concurrent switching` context). Both new `it` blocks go inside the `concurrent switching` context, which shares the `before` block that creates 5 tenants with a bumped pool size of 15 and `Widget` stub_const.

- [ ] **Step 2: Run the stress spec to verify all examples pass (including existing ones)**

Run: `DATABASE_ENGINE=postgresql bundle exec appraisal rails-8.1-postgresql rspec spec/integration/v4/stress_spec.rb --format documentation`

Expected: All examples pass including the two new ones. Existing examples unaffected.

- [ ] **Step 3: Commit**

```bash
git add spec/integration/v4/stress_spec.rb
git commit -m "Harden stress spec with tenant identity and isolation assertions

Add two new examples to the concurrent switching context:
- Explicit Tenant.current + Current.tenant check per thread
- Cross-tenant connection checkout isolation with dedicated tenants
  and barrier synchronization"
```

---

### Task 4: Create `cli_integration_spec.rb`

**Files:**
- Create: `spec/integration/v4/cli_integration_spec.rb`

- [ ] **Step 1: Write the spec file with all CLI integration tests**

```ruby
# frozen_string_literal: true

require 'spec_helper'
require_relative 'support'
require_relative '../../../lib/apartment/cli'

RSpec.describe('v4 CLI integration', :integration,
               skip: (V4_INTEGRATION_AVAILABLE ? false : 'requires ActiveRecord + database gem')) do
  include V4IntegrationHelper

  let(:tmp_dir) { Dir.mktmpdir('apartment_cli') }
  let(:tenants) { %w[cli_alpha cli_beta cli_gamma] }

  before do
    V4IntegrationHelper.ensure_test_database! unless V4IntegrationHelper.sqlite?
    config = V4IntegrationHelper.establish_default_connection!(tmp_dir: tmp_dir)
    V4IntegrationHelper.create_test_table!

    Apartment.configure do |c|
      c.tenant_strategy = V4IntegrationHelper.tenant_strategy
      c.tenants_provider = -> { tenants }
      c.default_tenant = V4IntegrationHelper.default_tenant
      c.check_pending_migrations = false
    end

    Apartment.adapter = V4IntegrationHelper.build_adapter(config)
    Apartment.activate!
  end

  after do
    tenants.each do |t|
      Apartment.adapter.drop(t)
    rescue StandardError
      nil
    end
    Apartment.clear_config
    Apartment::Current.reset
    if V4IntegrationHelper.sqlite?
      ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
      FileUtils.rm_rf(tmp_dir)
    end
  end

  describe 'tenants list' do
    it 'lists all tenants from tenants_provider' do
      output = capture_stdout { Apartment::CLI::Tenants.new.invoke(:list) }

      tenants.each do |t|
        expect(output).to(include(t), "Expected '#{t}' in list output")
      end
    end
  end

  describe 'tenants create' do
    it 'creates a tenant accessible via switch' do
      capture_stdout { Apartment::CLI::Tenants.new.invoke(:create, ['cli_alpha']) }

      Apartment::Tenant.switch('cli_alpha') do
        V4IntegrationHelper.create_test_table!('widgets', connection: ActiveRecord::Base.connection)
        ActiveRecord::Base.connection.execute('SELECT 1')
      end
    end
  end

  describe 'tenants drop' do
    it 'drops a tenant so it no longer exists' do
      Apartment.adapter.create('cli_alpha')

      ENV['APARTMENT_FORCE'] = '1'
      capture_stdout { Apartment::CLI::Tenants.new.invoke(:drop, ['cli_alpha']) }
      ENV.delete('APARTMENT_FORCE')

      expect do
        Apartment.adapter.drop('cli_alpha')
      end.to(raise_error(Apartment::TenantNotFound))
    end
  end

  describe 'pool stats' do
    it 'displays pool count and tenant names' do
      Apartment.adapter.create('cli_alpha')
      Apartment::Tenant.switch('cli_alpha') do
        ActiveRecord::Base.connection.execute('SELECT 1')
      end

      output = capture_stdout { Apartment::CLI::Pool.new.invoke(:stats) }

      expect(output).to(include('Total pools:'))
      expect(output).to(include('cli_alpha'))
    end
  end

  private

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end
end
```

- [ ] **Step 2: Run the spec on SQLite**

Run: `bundle exec appraisal rails-8.1-sqlite3 rspec spec/integration/v4/cli_integration_spec.rb --format documentation`

Expected: All 4 examples pass.

- [ ] **Step 3: Commit**

```bash
git add spec/integration/v4/cli_integration_spec.rb
git commit -m "Add CLI integration spec

Tests Thor CLI commands (tenants list/create/drop, pool stats)
against a real database. Uses APARTMENT_FORCE=1 to bypass
confirmation prompt on drop."
```

---

### Task 5: Drive-by fix — update `coverage_gaps_spec.rb` to use public `run_cycle` API

**Files:**
- Modify: `spec/integration/v4/coverage_gaps_spec.rb:164-166`

- [ ] **Step 1: Replace `send(:reap)` with `run_cycle`**

Change line 166 from:

```ruby
      Apartment.pool_reaper.send(:reap)
```

to:

```ruby
      Apartment.pool_reaper.run_cycle
```

Also update the comment on lines 164-165 from:

```ruby
      # Directly invoke reap to avoid timing-dependent background thread.
      # PoolReaper#reap is private — we test the observable effect.
```

to:

```ruby
      # Directly invoke run_cycle to avoid timing-dependent background thread.
```

- [ ] **Step 2: Run the coverage gaps spec to verify it still passes**

Run: `bundle exec appraisal rails-8.1-sqlite3 rspec spec/integration/v4/coverage_gaps_spec.rb --format documentation`

Expected: All examples pass. The LRU eviction test uses `run_cycle` now.

- [ ] **Step 3: Commit**

```bash
git add spec/integration/v4/coverage_gaps_spec.rb
git commit -m "Use public run_cycle API instead of send(:reap)

Drive-by fix: PoolReaper#reap is private and delegates to
run_cycle. Use the public API directly."
```

---

### Task 6: Run full integration suite across all engines

**Files:** None (verification only)

- [ ] **Step 1: Run SQLite integration suite**

Run: `bundle exec appraisal rails-8.1-sqlite3 rspec spec/integration/v4/ --format progress`

Expected: All non-skipped examples pass. Stress spec skips on SQLite (expected). Memory stability bounded/create-drop contexts skip on SQLite (expected). Fiber safety and CLI specs pass.

- [ ] **Step 2: Run PostgreSQL integration suite**

Run: `DATABASE_ENGINE=postgresql bundle exec appraisal rails-8.1-postgresql rspec spec/integration/v4/ --format progress`

Expected: All examples pass including stress, memory stability, fiber safety, and CLI.

- [ ] **Step 3: Run MySQL integration suite (if MySQL available locally)**

Run: `DATABASE_ENGINE=mysql bundle exec appraisal rails-8.1-mysql2 rspec spec/integration/v4/ --format progress`

Expected: All examples pass. If MySQL is not available locally, this step can be deferred to CI.

- [ ] **Step 4: Run rubocop on all changed files**

Run: `bundle exec rubocop spec/integration/v4/fiber_safety_spec.rb spec/integration/v4/memory_stability_spec.rb spec/integration/v4/cli_integration_spec.rb spec/integration/v4/stress_spec.rb spec/integration/v4/coverage_gaps_spec.rb`

Expected: No offenses. If ThreadSafety/NewThread fires on fiber_safety_spec.rb, add a rubocop:disable directive at the top (same pattern as stress_spec.rb).

- [ ] **Step 5: Run unit tests to verify no regressions**

Run: `bundle exec appraisal rails-8.1-sqlite3 rspec spec/unit/ --format progress`

Expected: All unit tests pass unchanged.
