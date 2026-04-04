# Phase 6: CLI & Generator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace inline rake task logic with a Thor CLI as the primary interface, refactor rake tasks to thin wrappers, rewrite the install generator for v4.

**Architecture:** Per-file Thor subcommands registered under `Apartment::CLI`. Each subcommand class handles one domain (tenants, migrations, seeds, pool). Rake tasks delegate to CLI classes. Two new public APIs on existing classes: `Migrator#migrate_one` and `PoolReaper#run_cycle`.

**Tech Stack:** Thor >= 1.3.0 (already a dependency), RSpec, Rails generators

**Design spec:** `docs/designs/v4-phase6-cli-generator.md`

---

## File Map

### New files
| File | Responsibility |
|------|---------------|
| `lib/apartment/cli.rb` | Entry point: registers subcommands |
| `lib/apartment/cli/tenants.rb` | `create`, `drop`, `list`, `current` commands |
| `lib/apartment/cli/migrations.rb` | `migrate`, `rollback` commands |
| `lib/apartment/cli/seeds.rb` | `seed` command |
| `lib/apartment/cli/pool.rb` | `stats`, `evict` commands |
| `lib/generators/apartment/install/templates/binstub` | `bin/apartment` template |
| `spec/unit/cli_spec.rb` | Subcommand registration tests |
| `spec/unit/cli/tenants_spec.rb` | Tenants CLI tests |
| `spec/unit/cli/migrations_spec.rb` | Migrations CLI tests |
| `spec/unit/cli/seeds_spec.rb` | Seeds CLI tests |
| `spec/unit/cli/pool_spec.rb` | Pool CLI tests |
| `spec/unit/generator/install_generator_spec.rb` | Generator tests |

### Modified files
| File | Change |
|------|--------|
| `lib/apartment/migrator.rb` | Add public `migrate_one(tenant)` method |
| `lib/apartment/pool_reaper.rb` | Add public `run_cycle` method, make `reap` delegate |
| `lib/apartment/tasks/v4.rake` | Replace inline logic with CLI delegation |
| `lib/generators/apartment/install/install_generator.rb` | Add binstub generation |
| `lib/generators/apartment/install/templates/apartment.rb` | Rewrite for v4 Config |
| `spec/unit/migrator_spec.rb` | Add `migrate_one` tests |
| `spec/unit/pool_reaper_spec.rb` | Add `run_cycle` tests |

---

## Phase 6.1: Thor CLI + Rake Refactor

### Task 1: `Migrator#migrate_one` — failing test

**Files:**
- Test: `spec/unit/migrator_spec.rb`

- [ ] **Step 1: Write the failing test for `migrate_one`**

Add to the end of `spec/unit/migrator_spec.rb`, before the final `end`:

```ruby
describe '#migrate_one' do
  let(:migrator) { described_class.new }
  let(:mock_migration_context) { instance_double('ActiveRecord::MigrationContext') }
  let(:mock_pool) { instance_double('ActiveRecord::ConnectionAdapters::ConnectionPool') }
  let(:mock_connection) { double('connection') }

  before do
    allow(ActiveRecord::Base).to(receive_messages(connection_pool: mock_pool, lease_connection: mock_connection))
    allow(mock_connection).to(receive(:instance_variable_get).and_return(true))
    allow(mock_connection).to(receive(:instance_variable_set))
    allow(mock_pool).to(receive(:migration_context).and_return(mock_migration_context))
    allow(mock_migration_context).to(receive_messages(needs_migration?: true, migrate: []))
    allow(Apartment::Instrumentation).to(receive(:instrument))
    allow(Apartment::Tenant).to(receive(:switch)) { |_tenant, &block| block.call }
  end

  it 'returns a single Result for the given tenant' do
    result = migrator.migrate_one('acme')
    expect(result).to(be_a(Apartment::Migrator::Result))
    expect(result.tenant).to(eq('acme'))
    expect(result.status).to(eq(:success))
  end

  it 'switches to the given tenant' do
    migrator.migrate_one('acme')
    expect(Apartment::Tenant).to(have_received(:switch).with('acme'))
  end

  it 'sets Current.migrating during execution' do
    migrating_during = nil
    allow(Apartment::Tenant).to(receive(:switch)) do |&block|
      migrating_during = Apartment::Current.migrating
      block&.call
    end
    migrator.migrate_one('acme')
    expect(migrating_during).to(be(true))
  end

  it 'clears Current.migrating after completion' do
    migrator.migrate_one('acme')
    expect(Apartment::Current.migrating).to(be_falsey)
  end

  it 'disables advisory locks' do
    migrator.migrate_one('acme')
    expect(mock_connection).to(have_received(:instance_variable_set)
      .with(:@advisory_locks_enabled, false))
  end

  it 'instruments the migration' do
    migrator.migrate_one('acme')
    expect(Apartment::Instrumentation).to(have_received(:instrument)
      .with(:migrate_tenant, hash_including(tenant: 'acme')))
  end

  it 'returns :skipped when no pending migrations' do
    allow(mock_migration_context).to(receive(:needs_migration?).and_return(false))
    result = migrator.migrate_one('acme')
    expect(result.status).to(eq(:skipped))
  end

  it 'captures errors and returns :failed' do
    allow(mock_migration_context).to(receive(:migrate).and_raise(StandardError, 'boom'))
    result = migrator.migrate_one('acme')
    expect(result.status).to(eq(:failed))
    expect(result.error.message).to(eq('boom'))
  end

  it 'respects version parameter' do
    migrator = described_class.new(version: 20_260_401_000_000)
    expect(mock_migration_context).to(receive(:migrate).with(20_260_401_000_000).and_return([]))
    migrator.migrate_one('acme')
  end

  it 'calls evict_migration_pools in ensure' do
    Apartment.configure do |c|
      c.tenant_strategy = :schema
      c.tenants_provider = -> { [] }
      c.default_tenant = 'public'
      c.migration_role = :db_manager
    end
    pool_manager = instance_double(Apartment::PoolManager)
    allow(Apartment).to(receive(:pool_manager).and_return(pool_manager))
    allow(pool_manager).to(receive(:evict_by_role).and_return([]))

    migrator = described_class.new
    migrator.migrate_one('acme')

    expect(pool_manager).to(have_received(:evict_by_role).with(:db_manager))
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/unit/migrator_spec.rb -e 'migrate_one' --format documentation`
Expected: FAIL with `NoMethodError: undefined method 'migrate_one'`

---

### Task 2: `Migrator#migrate_one` — implementation

**Files:**
- Modify: `lib/apartment/migrator.rb:40-43`

- [ ] **Step 3: Add `migrate_one` public method**

Insert after the `run` method (after line 74 in `lib/apartment/migrator.rb`), before the `private` keyword:

```ruby
    # Migrate a single named tenant. Reuses the same code path as the
    # all-tenants run (migrate_tenant), preserving RBAC role wrapping,
    # advisory lock disabling, Current.migrating flag, and instrumentation.
    # Returns a single Result.
    def migrate_one(tenant)
      with_migration_role { migrate_tenant(tenant) }
    ensure
      evict_migration_pools
    end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/unit/migrator_spec.rb -e 'migrate_one' --format documentation`
Expected: All 9 examples PASS

- [ ] **Step 5: Run full migrator spec to verify no regressions**

Run: `bundle exec rspec spec/unit/migrator_spec.rb --format documentation`
Expected: All existing tests still pass

- [ ] **Step 6: Commit**

```bash
git add lib/apartment/migrator.rb spec/unit/migrator_spec.rb
git commit -m "Add Migrator#migrate_one for single-tenant CLI migration

Public API that delegates to the existing migrate_tenant internals,
preserving RBAC role wrapping, advisory lock disabling, Current.migrating
lifecycle, and instrumentation. Used by CLI migrations command."
```

---

### Task 3: `PoolReaper#run_cycle` — failing test

**Files:**
- Test: `spec/unit/pool_reaper_spec.rb`

- [ ] **Step 7: Write the failing test for `run_cycle`**

Add before the final `end` in `spec/unit/pool_reaper_spec.rb`:

```ruby
describe '#run_cycle' do
  it 'performs one synchronous eviction pass and returns eviction count' do
    pool_manager.fetch_or_create('stale_a') { 'pool_a' }
    pool_manager.fetch_or_create('stale_b') { 'pool_b' }
    pool_manager.instance_variable_get(:@timestamps)['stale_a'] =
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - 10
    pool_manager.instance_variable_get(:@timestamps)['stale_b'] =
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - 10
    pool_manager.fetch_or_create('fresh') { 'pool_fresh' }

    count = reaper.run_cycle
    expect(count).to(eq(2))
    expect(pool_manager.tracked?('stale_a')).to(be(false))
    expect(pool_manager.tracked?('stale_b')).to(be(false))
    expect(pool_manager.tracked?('fresh')).to(be(true))
  end

  it 'returns 0 when nothing to evict' do
    pool_manager.fetch_or_create('fresh') { 'pool_fresh' }
    count = reaper.run_cycle
    expect(count).to(eq(0))
  end

  it 'does not require the background timer to be running' do
    expect(reaper).not_to(be_running)
    pool_manager.fetch_or_create('stale') { 'pool_stale' }
    pool_manager.instance_variable_get(:@timestamps)['stale'] =
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - 10

    count = reaper.run_cycle
    expect(count).to(eq(1))
  end

  it 'respects default_tenant protection' do
    protected_reaper = described_class.new(
      pool_manager: pool_manager,
      interval: 0.05,
      idle_timeout: 1,
      default_tenant: 'public',
      on_evict: on_evict
    )
    pool_manager.fetch_or_create('public') { 'pool_default' }
    pool_manager.instance_variable_get(:@timestamps)['public'] =
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - 9999
    pool_manager.fetch_or_create('stale') { 'pool_stale' }
    pool_manager.instance_variable_get(:@timestamps)['stale'] =
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - 10

    count = protected_reaper.run_cycle
    expect(count).to(eq(1))
    expect(pool_manager.tracked?('public')).to(be(true))
    expect(pool_manager.tracked?('stale')).to(be(false))
  end
end
```

- [ ] **Step 8: Run test to verify it fails**

Run: `bundle exec rspec spec/unit/pool_reaper_spec.rb -e 'run_cycle' --format documentation`
Expected: FAIL with `NoMethodError: undefined method 'run_cycle'`

---

### Task 4: `PoolReaper#run_cycle` — implementation

**Files:**
- Modify: `lib/apartment/pool_reaper.rb:48-67`

- [ ] **Step 9: Add `run_cycle` public method and refactor `reap`**

In `lib/apartment/pool_reaper.rb`, add `run_cycle` as a public method before the `private` keyword (line 49), and refactor the private `reap` to delegate:

Replace the section from `private` (line 49) through the end of the `reap` method (line 67):

```ruby
    # Perform one synchronous eviction pass (idle + LRU).
    # Returns the total number of pools evicted.
    # Called by the background timer and by CLI `pool evict`.
    def run_cycle
      count = 0
      count += evict_idle
      count += evict_lru if @max_total
      count
    rescue Apartment::ApartmentError => e
      warn "[Apartment::PoolReaper] #{e.class}: #{e.message}"
      0
    rescue StandardError => e
      warn "[Apartment::PoolReaper] Unexpected error: #{e.class}: #{e.message}"
      warn e.backtrace&.first(5)&.join("\n") if e.backtrace
      0
    end

    private

    def reap
      run_cycle
    end
```

Then update `evict_idle` to return a count. Replace the existing `evict_idle` method:

```ruby
    def evict_idle
      count = 0
      @pool_manager.idle_tenants(timeout: @idle_timeout).each do |tenant|
        next if default_tenant_pool?(tenant)

        pool = @pool_manager.remove(tenant)
        deregister_from_ar_handler(tenant)
        Instrumentation.instrument(:evict, tenant: tenant, reason: :idle)
        @on_evict&.call(tenant, pool)
        count += 1
      rescue StandardError => e
        warn "[Apartment::PoolReaper] Failed to evict tenant #{tenant}: #{e.class}: #{e.message}"
      end
      count
    end
```

And update `evict_lru` to return a count. Replace the existing `evict_lru` method:

```ruby
    def evict_lru
      excess = @pool_manager.stats[:total_pools] - @max_total
      return 0 if excess <= 0

      candidates = @pool_manager.lru_tenants(count: excess + 1)
      evicted = 0
      candidates.each do |tenant|
        break if evicted >= excess
        next if default_tenant_pool?(tenant)

        pool = @pool_manager.remove(tenant)
        deregister_from_ar_handler(tenant)
        Instrumentation.instrument(:evict, tenant: tenant, reason: :lru)
        @on_evict&.call(tenant, pool)
        evicted += 1
      rescue StandardError => e
        warn "[Apartment::PoolReaper] Failed to evict tenant #{tenant}: #{e.class}: #{e.message}"
      end
      evicted
    end
```

- [ ] **Step 10: Run `run_cycle` tests**

Run: `bundle exec rspec spec/unit/pool_reaper_spec.rb -e 'run_cycle' --format documentation`
Expected: All 4 examples PASS

- [ ] **Step 11: Run full pool_reaper spec to verify no regressions**

Run: `bundle exec rspec spec/unit/pool_reaper_spec.rb --format documentation`
Expected: All existing tests still pass (idle eviction, LRU eviction, protected tenants, error resilience, instrumentation)

- [ ] **Step 12: Commit**

```bash
git add lib/apartment/pool_reaper.rb spec/unit/pool_reaper_spec.rb
git commit -m "Add PoolReaper#run_cycle for synchronous eviction

Public method that performs one idle + LRU eviction pass and returns
the count of evicted pools. The background timer's private #reap
now delegates to run_cycle. Used by CLI pool evict command."
```

---

### Task 5: Zeitwerk ignore for `cli/` directory

**Files:**
- Modify: `lib/apartment.rb`

The `cli/` directory contains Thor subclasses that should be loaded explicitly by `cli.rb`, not autoloaded by Zeitwerk (they depend on Thor being required first).

- [ ] **Step 13: Add Zeitwerk ignore for cli directory**

In `lib/apartment.rb`, add after line 19 (`loader.ignore("#{__dir__}/apartment/tasks")`):

```ruby
# CLI Thor commands are loaded explicitly by cli.rb, not autoloaded.
loader.ignore("#{__dir__}/apartment/cli")
```

- [ ] **Step 14: Commit**

```bash
git add lib/apartment.rb
git commit -m "Ignore cli/ directory from Zeitwerk autoloading

Thor CLI commands are loaded explicitly by lib/apartment/cli.rb,
not autoloaded. Prevents Zeitwerk from trying to resolve them
before Thor is required."
```

---

### Task 6: `Apartment::CLI` entry point — test

**Files:**
- Create: `spec/unit/cli_spec.rb`

- [ ] **Step 15: Write the CLI registration test**

```ruby
# frozen_string_literal: true

require 'spec_helper'
require_relative '../../lib/apartment/cli'

RSpec.describe(Apartment::CLI) do
  describe '.exit_on_failure?' do
    it 'returns true' do
      expect(described_class.exit_on_failure?).to(be(true))
    end
  end

  describe 'subcommand registration' do
    it 'registers tenants subcommand' do
      expect(help_output).to(include('tenants'))
    end

    it 'registers migrations subcommand' do
      expect(help_output).to(include('migrations'))
    end

    it 'registers seeds subcommand' do
      expect(help_output).to(include('seeds'))
    end

    it 'registers pool subcommand' do
      expect(help_output).to(include('pool'))
    end
  end

  private

  def help_output
    @help_output ||= capture_stdout { described_class.start(['help']) }
  end

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

- [ ] **Step 16: Run test to verify it fails**

Run: `bundle exec rspec spec/unit/cli_spec.rb --format documentation`
Expected: FAIL with `LoadError: cannot load such file -- .../apartment/cli`

---

### Task 7: `Apartment::CLI` entry point — implementation

**Files:**
- Create: `lib/apartment/cli.rb`
- Create: `lib/apartment/cli/tenants.rb` (stub)
- Create: `lib/apartment/cli/migrations.rb` (stub)
- Create: `lib/apartment/cli/seeds.rb` (stub)
- Create: `lib/apartment/cli/pool.rb` (stub)

- [ ] **Step 17: Create the CLI entry point and stub subcommand files**

`lib/apartment/cli.rb`:
```ruby
# frozen_string_literal: true

require 'thor'
require_relative 'cli/tenants'
require_relative 'cli/migrations'
require_relative 'cli/seeds'
require_relative 'cli/pool'

module Apartment
  class CLI < Thor
    def self.exit_on_failure? = true

    register CLI::Tenants,    'tenants',    'tenants COMMAND',    'Tenant lifecycle commands'
    register CLI::Migrations, 'migrations', 'migrations COMMAND', 'Migration commands'
    register CLI::Seeds,      'seeds',      'seeds COMMAND',      'Seed commands'
    register CLI::Pool,       'pool',       'pool COMMAND',       'Connection pool commands'
  end
end
```

`lib/apartment/cli/tenants.rb`:
```ruby
# frozen_string_literal: true

require 'thor'

module Apartment
  class CLI < Thor
    class Tenants < Thor
      def self.exit_on_failure? = true
    end
  end
end
```

`lib/apartment/cli/migrations.rb`:
```ruby
# frozen_string_literal: true

require 'thor'

module Apartment
  class CLI < Thor
    class Migrations < Thor
      def self.exit_on_failure? = true
    end
  end
end
```

`lib/apartment/cli/seeds.rb`:
```ruby
# frozen_string_literal: true

require 'thor'

module Apartment
  class CLI < Thor
    class Seeds < Thor
      def self.exit_on_failure? = true
    end
  end
end
```

`lib/apartment/cli/pool.rb`:
```ruby
# frozen_string_literal: true

require 'thor'

module Apartment
  class CLI < Thor
    class Pool < Thor
      def self.exit_on_failure? = true
    end
  end
end
```

- [ ] **Step 18: Run test to verify it passes**

Run: `bundle exec rspec spec/unit/cli_spec.rb --format documentation`
Expected: All 5 examples PASS

- [ ] **Step 19: Commit**

```bash
git add lib/apartment/cli.rb lib/apartment/cli/ spec/unit/cli_spec.rb
git commit -m "Add Apartment::CLI entry point with subcommand registration

Registers Tenants, Migrations, Seeds, and Pool as Thor subcommands.
Subcommand classes are stubs; commands added in subsequent commits."
```

---

### Task 8: CLI Tenants — tests

**Files:**
- Create: `spec/unit/cli/tenants_spec.rb`

- [ ] **Step 20: Write the tenants CLI tests**

```ruby
# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../lib/apartment/cli'

RSpec.describe(Apartment::CLI::Tenants) do
  before do
    Apartment.configure do |c|
      c.tenant_strategy = :schema
      c.tenants_provider = -> { %w[acme beta] }
      c.default_tenant = 'public'
    end
  end

  def run_command(*args)
    output = StringIO.new
    $stdout = output
    described_class.start(args)
    output.string
  ensure
    $stdout = STDOUT
  end

  describe 'create' do
    before do
      allow(Apartment::Tenant).to(receive(:create))
    end

    it 'creates a single tenant when given an argument' do
      run_command('create', 'acme')
      expect(Apartment::Tenant).to(have_received(:create).with('acme'))
    end

    it 'creates all tenants when no argument given' do
      run_command('create')
      expect(Apartment::Tenant).to(have_received(:create).with('acme'))
      expect(Apartment::Tenant).to(have_received(:create).with('beta'))
    end

    it 'skips tenants that already exist' do
      allow(Apartment::Tenant).to(receive(:create).with('acme')
        .and_raise(Apartment::TenantExists.new('acme')))
      output = run_command('create')
      expect(output).to(include('already exists'))
    end

    it 'collects errors and reports failures' do
      allow(Apartment::Tenant).to(receive(:create).with('acme')
        .and_raise(StandardError, 'connection refused'))
      allow(Apartment::Tenant).to(receive(:create).with('beta'))
      expect { run_command('create') }.to(raise_error(SystemExit))
    end

    it 'suppresses per-tenant output with --quiet' do
      output = run_command('create', '--quiet')
      expect(output).not_to(include('Creating'))
    end
  end

  describe 'drop' do
    before do
      allow(Apartment::Tenant).to(receive(:drop))
    end

    it 'drops the specified tenant with --force' do
      run_command('drop', 'acme', '--force')
      expect(Apartment::Tenant).to(have_received(:drop).with('acme'))
    end

    it 'prompts for confirmation without --force' do
      instance = described_class.new
      allow(instance).to(receive(:yes?).and_return(false))
      allow(instance).to(receive(:say))
      instance.invoke(:drop, ['acme'])
      expect(Apartment::Tenant).not_to(have_received(:drop))
    end

    it 'proceeds when confirmation is accepted' do
      instance = described_class.new
      allow(instance).to(receive(:yes?).and_return(true))
      allow(instance).to(receive(:say))
      instance.invoke(:drop, ['acme'])
      expect(Apartment::Tenant).to(have_received(:drop).with('acme'))
    end
  end

  describe 'list' do
    it 'prints all tenant names' do
      output = run_command('list')
      expect(output).to(include('acme'))
      expect(output).to(include('beta'))
    end
  end

  describe 'current' do
    it 'prints the current tenant' do
      Apartment::Current.tenant = 'acme'
      output = run_command('current')
      expect(output.strip).to(eq('acme'))
    end

    it 'prints default_tenant when no current tenant' do
      output = run_command('current')
      expect(output.strip).to(eq('public'))
    end

    it 'prints none when no tenant context' do
      Apartment.configure do |c|
        c.tenant_strategy = :schema
        c.tenants_provider = -> { [] }
      end
      output = run_command('current')
      expect(output.strip).to(eq('none'))
    end
  end

  describe 'APARTMENT_FORCE env var' do
    before do
      allow(Apartment::Tenant).to(receive(:drop))
    end

    it 'skips confirmation when APARTMENT_FORCE=1' do
      ClimateControl.modify(APARTMENT_FORCE: '1') do
        run_command('drop', 'acme')
      end
      expect(Apartment::Tenant).to(have_received(:drop).with('acme'))
    end
  end

  describe 'APARTMENT_QUIET env var' do
    before do
      allow(Apartment::Tenant).to(receive(:create))
    end

    it 'suppresses output when APARTMENT_QUIET=1' do
      output = ClimateControl.modify(APARTMENT_QUIET: '1') { run_command('create') }
      expect(output).not_to(include('Creating'))
    end
  end
end
```

**Note:** The env var tests use `climate_control` gem. Check if it's already a dev dependency; if not, use `ENV` stubbing directly:

```ruby
# Alternative without climate_control:
it 'skips confirmation when APARTMENT_FORCE=1' do
  original = ENV.fetch('APARTMENT_FORCE', nil)
  ENV['APARTMENT_FORCE'] = '1'
  run_command('drop', 'acme')
  expect(Apartment::Tenant).to(have_received(:drop).with('acme'))
ensure
  ENV['APARTMENT_FORCE'] = original
end
```

Check the Gemfile for `climate_control` before deciding which pattern to use. If absent, use the `ENV` stubbing approach.

- [ ] **Step 21: Run tests to verify they fail**

Run: `bundle exec rspec spec/unit/cli/tenants_spec.rb --format documentation`
Expected: FAIL — `create`, `drop`, `list`, `current` methods not defined

---

### Task 9: CLI Tenants — implementation

**Files:**
- Modify: `lib/apartment/cli/tenants.rb`

- [ ] **Step 22: Implement the Tenants CLI**

Replace `lib/apartment/cli/tenants.rb` with:

```ruby
# frozen_string_literal: true

require 'thor'

module Apartment
  class CLI < Thor
    class Tenants < Thor
      def self.exit_on_failure? = true

      desc 'create [TENANT]', 'Create tenant schema/database'
      long_desc <<~DESC
        Without arguments, creates all tenants returned by tenants_provider.
        With a TENANT argument, creates only that tenant.
        Skips tenants that already exist (no error).
      DESC
      method_option :quiet, type: :boolean, desc: 'Suppress per-tenant output'
      def create(tenant = nil)
        if tenant
          create_single(tenant)
        else
          create_all
        end
      end

      desc 'drop TENANT', 'Drop a tenant schema/database'
      long_desc <<~DESC
        Drops the specified tenant. Requires confirmation unless --force is set.
        There is no "drop all" — this is intentionally a single-tenant operation.
      DESC
      method_option :force, type: :boolean, desc: 'Skip confirmation prompt'
      def drop(tenant)
        unless force?
          return say('Cancelled.') unless yes?("Drop tenant '#{tenant}'? This cannot be undone. [y/N]")
        end

        Apartment::Tenant.drop(tenant)
        say("Dropped tenant: #{tenant}") unless quiet?
      end

      desc 'list', 'List all tenants'
      def list
        Apartment.config.tenants_provider.call.each { |t| say(t) }
      end

      desc 'current', 'Show current tenant'
      def current
        say(Apartment::Current.tenant || Apartment.config&.default_tenant || 'none')
      end

      private

      def create_single(tenant)
        say("Creating tenant: #{tenant}") unless quiet?
        Apartment::Tenant.create(tenant)
        say("  created") unless quiet?
      rescue Apartment::TenantExists
        say("  already exists, skipping") unless quiet?
      end

      def create_all
        tenants = Apartment.config.tenants_provider.call
        failed = []
        tenants.each do |t|
          say("Creating tenant: #{t}") unless quiet?
          Apartment::Tenant.create(t)
          say("  created") unless quiet?
        rescue Apartment::TenantExists
          say("  already exists, skipping") unless quiet?
        rescue StandardError => e
          warn("  FAILED: #{e.message}")
          failed << t
        end
        return if failed.empty?

        raise(Thor::Error, "apartment tenants create failed for #{failed.size} tenant(s): #{failed.join(', ')}")
      end

      def force?
        options[:force] || ENV['APARTMENT_FORCE'] == '1'
      end

      def quiet?
        options[:quiet] || ENV['APARTMENT_QUIET'] == '1'
      end
    end
  end
end
```

- [ ] **Step 23: Run tests**

Run: `bundle exec rspec spec/unit/cli/tenants_spec.rb --format documentation`
Expected: All examples PASS (some env var tests may need adjustment based on climate_control availability)

- [ ] **Step 24: Commit**

```bash
git add lib/apartment/cli/tenants.rb spec/unit/cli/tenants_spec.rb
git commit -m "Add CLI tenants subcommand: create, drop, list, current

Supports single-tenant and all-tenants create, confirmation-gated drop,
list from tenants_provider, and current tenant display. Env var
overrides: APARTMENT_FORCE, APARTMENT_QUIET."
```

---

### Task 10: CLI Migrations — tests

**Files:**
- Create: `spec/unit/cli/migrations_spec.rb`

- [ ] **Step 25: Write the migrations CLI tests**

```ruby
# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../lib/apartment/cli'

RSpec.describe(Apartment::CLI::Migrations) do
  before do
    Apartment.configure do |c|
      c.tenant_strategy = :schema
      c.tenants_provider = -> { %w[acme beta] }
      c.default_tenant = 'public'
    end
  end

  def run_command(*args)
    output = StringIO.new
    $stdout = output
    described_class.start(args)
    output.string
  ensure
    $stdout = STDOUT
  end

  describe 'migrate' do
    let(:migration_run) do
      Apartment::Migrator::MigrationRun.new(
        results: [
          Apartment::Migrator::Result.new(
            tenant: 'public', status: :success, duration: 0.1, error: nil, versions_run: []
          ),
          Apartment::Migrator::Result.new(
            tenant: 'acme', status: :success, duration: 0.2, error: nil, versions_run: []
          ),
        ],
        total_duration: 0.3,
        threads: 0
      )
    end

    context 'without tenant argument (all tenants)' do
      before do
        allow(Apartment::Migrator).to(receive(:new).and_return(double(run: migration_run)))
        allow(ActiveRecord).to(receive(:dump_schema_after_migration).and_return(false))
      end

      it 'delegates to Migrator#run' do
        run_command('migrate')
        expect(Apartment::Migrator).to(have_received(:new))
      end

      it 'prints the migration summary' do
        output = run_command('migrate')
        expect(output).to(include('tenants'))
      end

      it 'passes --threads to Migrator' do
        expect(Apartment::Migrator).to(receive(:new)
          .with(hash_including(threads: 4)).and_return(double(run: migration_run)))
        run_command('migrate', '--threads=4')
      end

      it 'passes --version to Migrator' do
        expect(Apartment::Migrator).to(receive(:new)
          .with(hash_including(version: 20_260_401)).and_return(double(run: migration_run)))
        run_command('migrate', '--version=20260401')
      end

      it 'falls back to ENV VERSION when --version not given' do
        original = ENV.fetch('VERSION', nil)
        ENV['VERSION'] = '20260401'
        expect(Apartment::Migrator).to(receive(:new)
          .with(hash_including(version: 20_260_401)).and_return(double(run: migration_run)))
        run_command('migrate')
      ensure
        ENV['VERSION'] = original
      end

      it 'defaults threads to config value' do
        Apartment.configure do |c|
          c.tenant_strategy = :schema
          c.tenants_provider = -> { %w[acme] }
          c.default_tenant = 'public'
          c.parallel_migration_threads = 8
        end
        expect(Apartment::Migrator).to(receive(:new)
          .with(hash_including(threads: 8)).and_return(double(run: migration_run)))
        run_command('migrate')
      end

      it 'exits non-zero when migration fails' do
        failed_run = Apartment::Migrator::MigrationRun.new(
          results: [
            Apartment::Migrator::Result.new(
              tenant: 'acme', status: :failed, duration: 0.1,
              error: StandardError.new('boom'), versions_run: []
            ),
          ],
          total_duration: 0.1,
          threads: 0
        )
        allow(Apartment::Migrator).to(receive(:new).and_return(double(run: failed_run)))
        expect { run_command('migrate') }.to(raise_error(SystemExit))
      end
    end

    context 'with tenant argument (single tenant)' do
      let(:result) do
        Apartment::Migrator::Result.new(
          tenant: 'acme', status: :success, duration: 0.2, error: nil, versions_run: [1]
        )
      end

      before do
        allow(Apartment::Migrator).to(receive(:new).and_return(double(migrate_one: result)))
      end

      it 'delegates to Migrator#migrate_one' do
        migrator = double
        allow(Apartment::Migrator).to(receive(:new).and_return(migrator))
        expect(migrator).to(receive(:migrate_one).with('acme').and_return(result))
        run_command('migrate', 'acme')
      end

      it 'prints success message' do
        output = run_command('migrate', 'acme')
        expect(output).to(include('acme'))
      end

      it 'exits non-zero on failure' do
        failed = Apartment::Migrator::Result.new(
          tenant: 'acme', status: :failed, duration: 0.1,
          error: StandardError.new('boom'), versions_run: []
        )
        allow(Apartment::Migrator).to(receive(:new).and_return(double(migrate_one: failed)))
        expect { run_command('migrate', 'acme') }.to(raise_error(SystemExit))
      end
    end
  end

  describe 'rollback' do
    let(:mock_migration_context) { double('MigrationContext') }
    let(:mock_pool) { double('pool', migration_context: mock_migration_context) }

    before do
      allow(mock_migration_context).to(receive(:rollback))
      allow(ActiveRecord::Base).to(receive(:connection_pool).and_return(mock_pool))
      allow(Apartment::Tenant).to(receive(:switch)) { |_t, &block| block.call }
    end

    it 'rolls back all tenants by default' do
      run_command('rollback')
      expect(Apartment::Tenant).to(have_received(:switch).with('acme'))
      expect(Apartment::Tenant).to(have_received(:switch).with('beta'))
      expect(mock_migration_context).to(have_received(:rollback).with(1).twice)
    end

    it 'rolls back a single tenant when given' do
      run_command('rollback', 'acme')
      expect(Apartment::Tenant).to(have_received(:switch).with('acme'))
      expect(Apartment::Tenant).not_to(have_received(:switch).with('beta'))
    end

    it 'respects --step option' do
      run_command('rollback', '--step=3')
      expect(mock_migration_context).to(have_received(:rollback).with(3).twice)
    end

    it 'exits non-zero when a tenant fails' do
      allow(Apartment::Tenant).to(receive(:switch).with('acme')
        .and_raise(StandardError, 'boom'))
      allow(Apartment::Tenant).to(receive(:switch).with('beta')) { |_t, &block| block.call }
      expect { run_command('rollback') }.to(raise_error(SystemExit))
    end
  end
end
```

- [ ] **Step 26: Run tests to verify they fail**

Run: `bundle exec rspec spec/unit/cli/migrations_spec.rb --format documentation`
Expected: FAIL — `migrate`, `rollback` methods not defined

---

### Task 11: CLI Migrations — implementation

**Files:**
- Modify: `lib/apartment/cli/migrations.rb`

- [ ] **Step 27: Implement the Migrations CLI**

Replace `lib/apartment/cli/migrations.rb` with:

```ruby
# frozen_string_literal: true

require 'thor'

module Apartment
  class CLI < Thor
    class Migrations < Thor
      def self.exit_on_failure? = true

      desc 'migrate [TENANT]', 'Run migrations for tenants'
      long_desc <<~DESC
        Without arguments, migrates all tenants (primary DB first, then tenants
        from tenants_provider). With a TENANT argument, migrates only that tenant.

        Uses Apartment::Migrator for both paths, preserving RBAC role wrapping,
        advisory lock management, and instrumentation.
      DESC
      method_option :version, type: :numeric, desc: 'Target migration version (also reads ENV VERSION)'
      method_option :threads, type: :numeric, desc: 'Override parallel_migration_threads from config'
      def migrate(tenant = nil)
        require 'apartment/migrator'

        if tenant
          migrate_single(tenant)
        else
          migrate_all
        end
      end

      desc 'rollback [TENANT]', 'Rollback migrations for tenants'
      long_desc <<~DESC
        Without arguments, rolls back all tenants sequentially.
        With a TENANT argument, rolls back only that tenant.
      DESC
      method_option :step, type: :numeric, default: 1, desc: 'Number of steps to rollback'
      def rollback(tenant = nil)
        if tenant
          rollback_single(tenant)
        else
          rollback_all
        end
      end

      private

      def migrate_single(tenant)
        migrator = Apartment::Migrator.new(version: resolve_version)
        result = migrator.migrate_one(tenant)
        if result.status == :failed
          raise(Thor::Error, "Migration failed for #{tenant}: #{result.error&.class}: #{result.error&.message}")
        end

        say("Migrated tenant: #{tenant} (#{result.status}, #{result.duration.round(2)}s)")
      end

      def migrate_all
        threads = options[:threads] || Apartment.config.parallel_migration_threads
        migrator = Apartment::Migrator.new(threads: threads, version: resolve_version)
        result = migrator.run
        say(result.summary)

        trigger_schema_dump if result.success?
        raise(Thor::Error, "Migration failed for #{result.failed.size} tenant(s)") unless result.success?
      end

      def rollback_single(tenant)
        step = options[:step]
        say("Rolling back tenant: #{tenant} (#{step} step(s))")
        Apartment::Tenant.switch(tenant) do
          ActiveRecord::Base.connection_pool.migration_context.rollback(step)
        end
        say("  done")
      end

      def rollback_all
        step = options[:step]
        tenants = Apartment.config.tenants_provider.call
        failed = []
        tenants.each do |t|
          say("Rolling back tenant: #{t} (#{step} step(s))")
          Apartment::Tenant.switch(t) do
            ActiveRecord::Base.connection_pool.migration_context.rollback(step)
          end
          say("  done")
        rescue StandardError => e
          warn("  FAILED: #{e.message}")
          failed << t
        end
        return if failed.empty?

        raise(Thor::Error, "Rollback failed for #{failed.size} tenant(s): #{failed.join(', ')}")
      end

      def resolve_version
        v = options[:version] || ENV['VERSION']&.to_i
        v&.zero? ? nil : v
      end

      def trigger_schema_dump
        return unless defined?(ActiveRecord) && ActiveRecord.dump_schema_after_migration
        return unless defined?(Rake::Task) && Rake::Task.task_defined?('db:schema:dump')

        Rake::Task['db:schema:dump'].invoke
      end
    end
  end
end
```

- [ ] **Step 28: Run tests**

Run: `bundle exec rspec spec/unit/cli/migrations_spec.rb --format documentation`
Expected: All examples PASS

- [ ] **Step 29: Commit**

```bash
git add lib/apartment/cli/migrations.rb spec/unit/cli/migrations_spec.rb
git commit -m "Add CLI migrations subcommand: migrate, rollback

migrate delegates to Migrator#run (all) or Migrator#migrate_one (single).
Supports --version, --threads, and ENV VERSION fallback. rollback iterates
tenants sequentially with --step option."
```

---

### Task 12: CLI Seeds — tests

**Files:**
- Create: `spec/unit/cli/seeds_spec.rb`

- [ ] **Step 30: Write the seeds CLI tests**

```ruby
# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../lib/apartment/cli'

RSpec.describe(Apartment::CLI::Seeds) do
  before do
    Apartment.configure do |c|
      c.tenant_strategy = :schema
      c.tenants_provider = -> { %w[acme beta] }
      c.default_tenant = 'public'
    end
    allow(Apartment::Tenant).to(receive(:seed))
  end

  def run_command(*args)
    output = StringIO.new
    $stdout = output
    described_class.start(args)
    output.string
  ensure
    $stdout = STDOUT
  end

  describe 'seed' do
    it 'seeds a single tenant when given an argument' do
      run_command('seed', 'acme')
      expect(Apartment::Tenant).to(have_received(:seed).with('acme'))
    end

    it 'seeds all tenants when no argument given' do
      run_command('seed')
      expect(Apartment::Tenant).to(have_received(:seed).with('acme'))
      expect(Apartment::Tenant).to(have_received(:seed).with('beta'))
    end

    it 'collects errors and exits non-zero' do
      allow(Apartment::Tenant).to(receive(:seed).with('acme')
        .and_raise(StandardError, 'seed error'))
      expect { run_command('seed') }.to(raise_error(SystemExit))
    end

    it 'prints per-tenant output' do
      output = run_command('seed')
      expect(output).to(include('acme'))
      expect(output).to(include('beta'))
    end
  end
end
```

- [ ] **Step 31: Run tests to verify they fail**

Run: `bundle exec rspec spec/unit/cli/seeds_spec.rb --format documentation`
Expected: FAIL — `seed` method not defined

---

### Task 13: CLI Seeds — implementation

**Files:**
- Modify: `lib/apartment/cli/seeds.rb`

- [ ] **Step 32: Implement the Seeds CLI**

Replace `lib/apartment/cli/seeds.rb` with:

```ruby
# frozen_string_literal: true

require 'thor'

module Apartment
  class CLI < Thor
    class Seeds < Thor
      def self.exit_on_failure? = true

      desc 'seed [TENANT]', 'Seed tenant databases'
      long_desc <<~DESC
        Without arguments, seeds all tenants from tenants_provider.
        With a TENANT argument, seeds only that tenant.
      DESC
      def seed(tenant = nil)
        if tenant
          seed_single(tenant)
        else
          seed_all
        end
      end

      private

      def seed_single(tenant)
        say("Seeding tenant: #{tenant}")
        Apartment::Tenant.seed(tenant)
        say("  done")
      end

      def seed_all
        tenants = Apartment.config.tenants_provider.call
        failed = []
        tenants.each do |t|
          say("Seeding tenant: #{t}")
          Apartment::Tenant.seed(t)
          say("  done")
        rescue StandardError => e
          warn("  FAILED: #{e.message}")
          failed << t
        end
        return if failed.empty?

        raise(Thor::Error, "Seed failed for #{failed.size} tenant(s): #{failed.join(', ')}")
      end
    end
  end
end
```

- [ ] **Step 33: Run tests**

Run: `bundle exec rspec spec/unit/cli/seeds_spec.rb --format documentation`
Expected: All 4 examples PASS

- [ ] **Step 34: Commit**

```bash
git add lib/apartment/cli/seeds.rb spec/unit/cli/seeds_spec.rb
git commit -m "Add CLI seeds subcommand

Supports single-tenant and all-tenants seeding via Apartment::Tenant.seed.
Collects errors across tenants and exits non-zero on failure."
```

---

### Task 14: CLI Pool — tests

**Files:**
- Create: `spec/unit/cli/pool_spec.rb`

- [ ] **Step 35: Write the pool CLI tests**

```ruby
# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../lib/apartment/cli'

RSpec.describe(Apartment::CLI::Pool) do
  def run_command(*args)
    output = StringIO.new
    $stdout = output
    described_class.start(args)
    output.string
  ensure
    $stdout = STDOUT
  end

  describe 'stats' do
    context 'when pool_manager is configured' do
      before do
        Apartment.configure do |c|
          c.tenant_strategy = :schema
          c.tenants_provider = -> { %w[acme beta] }
          c.default_tenant = 'public'
        end
      end

      it 'prints pool summary' do
        Apartment.pool_manager.fetch_or_create('acme') { double('pool') }
        output = run_command('stats')
        expect(output).to(include('pool'))
      end

      it 'prints per-tenant details with --verbose' do
        Apartment.pool_manager.fetch_or_create('acme') { double('pool') }
        output = run_command('stats', '--verbose')
        expect(output).to(include('acme'))
      end
    end

    context 'when pool_manager is nil' do
      before { Apartment.clear_config }

      it 'prints a not-configured message' do
        output = run_command('stats')
        expect(output).to(include('not configured'))
      end
    end
  end

  describe 'evict' do
    before do
      Apartment.configure do |c|
        c.tenant_strategy = :schema
        c.tenants_provider = -> { [] }
        c.default_tenant = 'public'
      end
    end

    it 'runs eviction cycle with --force' do
      allow(Apartment.pool_reaper).to(receive(:run_cycle).and_return(3))
      output = run_command('evict', '--force')
      expect(output).to(include('3'))
      expect(Apartment.pool_reaper).to(have_received(:run_cycle))
    end

    it 'prompts without --force' do
      instance = described_class.new
      allow(instance).to(receive(:yes?).and_return(false))
      allow(instance).to(receive(:say))
      instance.invoke(:evict)
      expect(Apartment.pool_reaper).not_to(have_received(:run_cycle)) if Apartment.pool_reaper
    end

    it 'reports when pool_reaper is nil' do
      Apartment.clear_config
      output = run_command('evict', '--force')
      expect(output).to(include('not configured'))
    end
  end
end
```

- [ ] **Step 36: Run tests to verify they fail**

Run: `bundle exec rspec spec/unit/cli/pool_spec.rb --format documentation`
Expected: FAIL — `stats`, `evict` methods not defined

---

### Task 15: CLI Pool — implementation

**Files:**
- Modify: `lib/apartment/cli/pool.rb`

- [ ] **Step 37: Implement the Pool CLI**

Replace `lib/apartment/cli/pool.rb` with:

```ruby
# frozen_string_literal: true

require 'thor'

module Apartment
  class CLI < Thor
    class Pool < Thor
      def self.exit_on_failure? = true

      desc 'stats', 'Show connection pool statistics'
      long_desc <<~DESC
        Displays pool summary: total pools and tenant list.
        With --verbose, shows per-tenant idle time.
      DESC
      method_option :verbose, type: :boolean, desc: 'Per-tenant breakdown'
      def stats
        unless Apartment.pool_manager
          say('Apartment is not configured. Run Apartment.configure first.')
          return
        end

        pool_stats = Apartment.pool_manager.stats
        say("Total pools: #{pool_stats[:total_pools]}")

        if options[:verbose] && pool_stats[:tenants]&.any?
          say("\nPer-tenant details:")
          pool_stats[:tenants].each do |tenant_key|
            tenant_stats = Apartment.pool_manager.stats_for(tenant_key)
            idle = tenant_stats ? "#{tenant_stats[:seconds_idle].round(1)}s idle" : 'unknown'
            say("  #{tenant_key}: #{idle}")
          end
        elsif pool_stats[:tenants]&.any?
          say("Tenants: #{pool_stats[:tenants].join(', ')}")
        end
      end

      desc 'evict', 'Force idle pool eviction'
      long_desc <<~DESC
        Triggers one synchronous eviction cycle (idle + LRU).
        Requires confirmation unless --force is set.
      DESC
      method_option :force, type: :boolean, desc: 'Skip confirmation prompt'
      def evict
        unless Apartment.pool_reaper
          say('Apartment is not configured. Run Apartment.configure first.')
          return
        end

        unless force?
          return say('Cancelled.') unless yes?('Run pool eviction cycle? [y/N]')
        end

        count = Apartment.pool_reaper.run_cycle
        say("Evicted #{count} pool(s).")
      end

      private

      def force?
        options[:force] || ENV['APARTMENT_FORCE'] == '1'
      end
    end
  end
end
```

- [ ] **Step 38: Run tests**

Run: `bundle exec rspec spec/unit/cli/pool_spec.rb --format documentation`
Expected: All examples PASS

- [ ] **Step 39: Commit**

```bash
git add lib/apartment/cli/pool.rb spec/unit/cli/pool_spec.rb
git commit -m "Add CLI pool subcommand: stats, evict

stats shows pool summary with optional --verbose per-tenant breakdown.
evict triggers PoolReaper#run_cycle with confirmation gate.
Both guard against nil pool_manager/pool_reaper."
```

---

### Task 16: Rake refactor

**Files:**
- Modify: `lib/apartment/tasks/v4.rake`

- [ ] **Step 40: Replace v4.rake with thin CLI wrappers**

Replace the entire contents of `lib/apartment/tasks/v4.rake` with:

```ruby
# frozen_string_literal: true

require 'apartment/cli'

namespace :apartment do
  desc 'Create all tenant schemas/databases (or one: rake apartment:create[tenant])'
  task :create, [:tenant] => :environment do |_t, args|
    if args[:tenant]
      Apartment::CLI::Tenants.new.invoke(:create, [args[:tenant]])
    else
      Apartment::CLI::Tenants.new.invoke(:create)
    end
  end

  desc 'Drop a tenant schema/database'
  task :drop, [:tenant] => :environment do |_t, args|
    abort('Usage: rake apartment:drop[tenant_name]') unless args[:tenant]
    Apartment::CLI::Tenants.new.invoke(:drop, [args[:tenant]], force: true)
  end

  desc 'Run migrations for all tenants'
  task migrate: :environment do
    Apartment::CLI::Migrations.new.invoke(:migrate)
  end

  desc 'Seed all tenants'
  task seed: :environment do
    Apartment::CLI::Seeds.new.invoke(:seed)
  end

  desc 'Rollback migrations for all tenants'
  task :rollback, [:step] => :environment do |_t, args|
    Apartment::CLI::Migrations.new.invoke(:rollback, [], step: (args[:step] || 1).to_i)
  end

  namespace :schema do
    namespace :cache do
      desc 'Dump schema cache for each tenant'
      task dump: :environment do
        require 'apartment/schema_cache'
        paths = Apartment::SchemaCache.dump_all
        paths.each { |p| puts("Dumped: #{p}") }
      end
    end
  end
end
```

**Note:** `drop` via rake passes `force: true` because rake tasks are non-interactive. The Thor command handles confirmation; rake skips it.

- [ ] **Step 41: Run the full unit test suite to verify no regressions**

Run: `bundle exec rspec spec/unit/ --format documentation`
Expected: All tests pass

- [ ] **Step 42: Commit**

```bash
git add lib/apartment/tasks/v4.rake
git commit -m "Refactor v4.rake to thin wrappers delegating to CLI

Logic now lives in Thor CLI classes. Rake tasks are one-liners that
invoke the corresponding CLI method. Rake drop passes force: true
(non-interactive). Schema cache dump stays as-is."
```

---

### Task 17: Full test run and lint

- [ ] **Step 43: Run full unit test suite**

Run: `bundle exec rspec spec/unit/ --format documentation`
Expected: All tests pass

- [ ] **Step 44: Run rubocop**

Run: `bundle exec rubocop lib/apartment/cli.rb lib/apartment/cli/ lib/apartment/migrator.rb lib/apartment/pool_reaper.rb lib/apartment/tasks/v4.rake`
Expected: No offenses. If there are offenses, fix them.

- [ ] **Step 45: Run tests across Rails versions**

Run: `bundle exec appraisal rails-8.1-sqlite3 rspec spec/unit/`
Expected: All tests pass

- [ ] **Step 46: Commit any lint fixes**

Only if Step 44 produced fixes:
```bash
git add -A
git commit -m "Fix rubocop offenses in CLI files"
```

---

## Phase 6.2: Generator + Binstub

### Task 18: Generator spec

**Files:**
- Create: `spec/unit/generator/install_generator_spec.rb`

- [ ] **Step 47: Write the generator test**

```ruby
# frozen_string_literal: true

require 'spec_helper'
require 'rails/generators'
require 'rails/generators/testing/behaviour'
require 'rails/generators/testing/assertions'
require_relative '../../../lib/generators/apartment/install/install_generator'

RSpec.describe(Apartment::InstallGenerator) do
  include FileUtils

  let(:destination) { Dir.mktmpdir }

  before do
    described_class.start([], destination_root: destination, quiet: true)
  end

  after do
    rm_rf(destination)
  end

  describe 'initializer' do
    let(:initializer_path) { File.join(destination, 'config', 'initializers', 'apartment.rb') }

    it 'creates the initializer file' do
      expect(File.exist?(initializer_path)).to(be(true))
    end

    it 'contains tenant_strategy' do
      content = File.read(initializer_path)
      expect(content).to(include('config.tenant_strategy'))
    end

    it 'contains tenants_provider' do
      content = File.read(initializer_path)
      expect(content).to(include('config.tenants_provider'))
    end

    it 'does not contain v3 references' do
      content = File.read(initializer_path)
      expect(content).not_to(include('tenant_names'))
      expect(content).not_to(include('use_schemas'))
      expect(content).not_to(include('use_sql'))
      expect(content).not_to(include('prepend_environment'))
      expect(content).not_to(include('pg_excluded_names'))
      expect(content).not_to(include('middleware.use'))
    end

    it 'does not require elevator files' do
      content = File.read(initializer_path)
      expect(content).not_to(include("require 'apartment/elevators"))
    end

    it 'includes RBAC options in comments' do
      content = File.read(initializer_path)
      expect(content).to(include('migration_role'))
      expect(content).to(include('app_role'))
    end

    it 'includes elevator options in comments' do
      content = File.read(initializer_path)
      expect(content).to(include('config.elevator'))
      expect(content).to(include('elevator_options'))
    end
  end

  describe 'binstub' do
    let(:binstub_path) { File.join(destination, 'bin', 'apartment') }

    it 'creates the binstub file' do
      expect(File.exist?(binstub_path)).to(be(true))
    end

    it 'is executable' do
      expect(File.executable?(binstub_path)).to(be(true))
    end

    it 'requires config/environment' do
      content = File.read(binstub_path)
      expect(content).to(include("require_relative '../config/environment'"))
    end

    it 'requires apartment/cli' do
      content = File.read(binstub_path)
      expect(content).to(include("require 'apartment/cli'"))
    end

    it 'starts CLI' do
      content = File.read(binstub_path)
      expect(content).to(include('Apartment::CLI.start'))
    end
  end
end
```

- [ ] **Step 48: Run test to verify it fails**

Run: `bundle exec rspec spec/unit/generator/install_generator_spec.rb --format documentation`
Expected: FAIL — binstub template not found / binstub not created

---

### Task 19: Generator implementation

**Files:**
- Modify: `lib/generators/apartment/install/install_generator.rb`
- Rewrite: `lib/generators/apartment/install/templates/apartment.rb`
- Create: `lib/generators/apartment/install/templates/binstub`

- [ ] **Step 49: Update the install generator**

Replace `lib/generators/apartment/install/install_generator.rb` with:

```ruby
# frozen_string_literal: true

module Apartment
  class InstallGenerator < Rails::Generators::Base
    source_root File.expand_path('templates', __dir__)

    def copy_initializer
      template('apartment.rb', File.join('config', 'initializers', 'apartment.rb'))
    end

    def copy_binstub
      template('binstub', File.join('bin', 'apartment'))
      chmod(File.join('bin', 'apartment'), 0o755)
    end
  end
end
```

- [ ] **Step 50: Rewrite the initializer template**

Replace `lib/generators/apartment/install/templates/apartment.rb` with:

```ruby
# frozen_string_literal: true

Apartment.configure do |config|
  # == Required ===========================================================

  # Tenant isolation strategy.
  #   :schema         - PostgreSQL schemas (one schema per tenant, single DB)
  #   :database_name  - Separate database per tenant (MySQL, PostgreSQL)
  config.tenant_strategy = :schema

  # Returns an array of tenant identifiers. Called at runtime by migrate,
  # create, seed, and other bulk operations.
  config.tenants_provider = -> { raise "TODO: replace with e.g. Account.pluck(:subdomain)" }

  # == Tenant Defaults =====================================================

  # The default tenant (used on boot and between requests).
  # config.default_tenant = 'public'

  # Models that live in the shared/default schema (not per-tenant).
  # config.excluded_models = %w[Account]

  # == Connection Pool =====================================================

  # config.tenant_pool_size      = 5
  # config.pool_idle_timeout     = 300
  # config.max_total_connections = nil

  # == Elevator (Request Tenant Detection) =================================

  # The Railtie auto-inserts the elevator as middleware. No manual
  # middleware.use call needed.
  #
  # config.elevator = :subdomain
  # config.elevator_options = {}

  # == Migrations ==========================================================

  # config.parallel_migration_threads = 0
  # config.schema_load_strategy       = nil  # :schema_rb or :sql
  # config.seed_after_create           = false
  # config.check_pending_migrations    = true

  # == RBAC & Roles =========================================================

  # config.migration_role          = nil   # e.g. :db_manager (Phase 5 role-aware connections)
  # config.app_role                = nil   # e.g. 'app_role' or -> { "app_#{Rails.env}" }
  # config.environmentify_strategy = nil   # nil, :prepend, :append, or a callable

  # == PostgreSQL ===========================================================

  # config.configure_postgres do |pg|
  #   pg.persistent_schemas = %w[shared extensions]
  # end

  # == MySQL ================================================================

  # config.configure_mysql do |my|
  # end
end
```

- [ ] **Step 51: Create the binstub template**

Create `lib/generators/apartment/install/templates/binstub`:

```ruby
#!/usr/bin/env ruby
require_relative '../config/environment'
require 'apartment/cli'
Apartment::CLI.start(ARGV)
```

- [ ] **Step 52: Run tests**

Run: `bundle exec rspec spec/unit/generator/install_generator_spec.rb --format documentation`
Expected: All examples PASS

- [ ] **Step 53: Commit**

```bash
git add lib/generators/apartment/install/ spec/unit/generator/
git commit -m "Rewrite install generator for v4: initializer + binstub

Initializer template uses v4 Config API with minimal scaffold (only
tenant_strategy and tenants_provider uncommented). Adds bin/apartment
binstub generation. No v3 references (tenant_names, use_schemas,
manual middleware insertion)."
```

---

### Task 20: Final validation

- [ ] **Step 54: Run full unit test suite**

Run: `bundle exec rspec spec/unit/ --format documentation`
Expected: All tests pass

- [ ] **Step 55: Run rubocop on all changed files**

Run: `bundle exec rubocop lib/generators/ spec/unit/generator/`
Expected: No offenses

- [ ] **Step 56: Run across Rails versions**

Run: `bundle exec appraisal rails-8.1-sqlite3 rspec spec/unit/`
Expected: All tests pass

- [ ] **Step 57: Commit any fixes**

Only if needed:
```bash
git add -A
git commit -m "Fix lint offenses in generator files"
```
