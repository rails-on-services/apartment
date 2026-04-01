# v4 Migrations (Phase 4) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement `Apartment::Migrator` for parallel tenant migrations with RBAC credential separation, plus schema dumper patch and rake task integration.

**Architecture:** Standalone Migrator with its own ephemeral PoolManager instance. Thread-based parallelism via `Queue`. `Data.define` for immutable result tracking. Schema dumper patch conditionally applied for Rails 8.1+. Rake tasks delegate to Migrator; Railtie enhances `db:migrate:DBNAME`.

**Tech Stack:** Ruby 3.2+ (`Data.define`), `concurrent-ruby` (`Concurrent::Array`), ActiveRecord `MigrationContext`, ActiveSupport::Notifications

**Spec:** `docs/designs/v4-migrations.md`

---

## File Structure

```
lib/apartment/
├── migrator.rb              # NEW — Migrator, Result, MigrationRun (orchestration + result types)
├── schema_dumper_patch.rb   # NEW — Rails 8.1 public. prefix stripping for SchemaDumper
├── config.rb                # MODIFY — add migration_db_config, schema_cache_per_tenant; remove parallel_strategy
├── errors.rb                # MODIFY — add MigrationError
├── tasks/v4.rake            # MODIFY — wire apartment:migrate/rollback through Migrator
├── railtie.rb               # MODIFY — add db:migrate:DBNAME enhancement hook
├── instrumentation.rb       # NO CHANGE — existing instrument() supports new events

spec/unit/
├── migrator_spec.rb              # NEW — Migrator core logic, threading, results
├── schema_dumper_patch_spec.rb   # NEW — prefix stripping logic

spec/integration/v4/
├── migrator_integration_spec.rb  # NEW — end-to-end migration with real databases
```

---

### Task 1: Config Changes — Remove `parallel_strategy`, Add New Keys

**Files:**
- Modify: `lib/apartment/config.rb:12,16,39-40,60-67,94-101,105-139`
- Modify: `spec/unit/config_spec.rb:19,30-40`

- [ ] **Step 1: Write failing tests for new config keys**

Add to `spec/unit/config_spec.rb`:

```ruby
# In 'defaults' describe block:
it { expect(config.migration_db_config).to(be_nil) }
it { expect(config.schema_cache_per_tenant).to(be(false)) }

# Remove this line:
# it { expect(config.parallel_strategy).to(eq(:auto)) }

# New describe block:
describe '#migration_db_config=' do
  it 'accepts nil' do
    config.migration_db_config = nil
    expect(config.migration_db_config).to(be_nil)
  end

  it 'accepts a symbol' do
    config.migration_db_config = :db_manager
    expect(config.migration_db_config).to(eq(:db_manager))
  end

  it 'rejects non-symbol, non-nil values' do
    expect { config.migration_db_config = 'db_manager' }.to(raise_error(
      Apartment::ConfigurationError, /migration_db_config must be nil or a Symbol/
    ))
  end
end

describe '#schema_cache_per_tenant=' do
  it 'accepts boolean values' do
    config.schema_cache_per_tenant = true
    expect(config.schema_cache_per_tenant).to(be(true))
  end
end
```

Remove the `#parallel_strategy=` test block entirely.

- [ ] **Step 2: Run tests to verify failures**

Run: `bundle exec rspec spec/unit/config_spec.rb -v`
Expected: Failures for new config keys, possible failure from removed parallel_strategy test

- [ ] **Step 3: Implement config changes**

In `lib/apartment/config.rb`:

1. Remove `VALID_PARALLEL_STRATEGIES` constant (line 12)
2. Remove `parallel_strategy` from `attr_reader` (line 16)
3. Add `migration_db_config` and `schema_cache_per_tenant` to `attr_accessor` (line 22 area)
4. In `initialize`: remove `@parallel_strategy = :auto` (line 40), add `@migration_db_config = nil` and `@schema_cache_per_tenant = false`
5. Remove `parallel_strategy=` setter method (lines 60-67)
6. Add `migration_db_config=` setter with validation:

```ruby
def migration_db_config=(value)
  unless value.nil? || value.is_a?(Symbol)
    raise(ConfigurationError, "migration_db_config must be nil or a Symbol referencing a database.yml config, " \
                              "got: #{value.inspect}")
  end

  @migration_db_config = value
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/unit/config_spec.rb -v`
Expected: All pass

- [ ] **Step 5: Run full unit suite to check for breakage**

Run: `bundle exec rspec spec/unit/ -v`
Expected: All pass. If any specs reference `parallel_strategy`, update them.

- [ ] **Step 6: Commit**

```bash
git add lib/apartment/config.rb spec/unit/config_spec.rb
git commit -m "Config: add migration_db_config, schema_cache_per_tenant; remove parallel_strategy"
```

---

### Task 2: Add MigrationError to Error Hierarchy

**Files:**
- Modify: `lib/apartment/errors.rb:37`
- Modify: `spec/unit/errors_spec.rb` (if exists, otherwise skip test file)

- [ ] **Step 1: Add error class**

Append to `lib/apartment/errors.rb` before the closing `end`:

```ruby
# Raised when a tenant migration fails. Wraps the original exception.
class MigrationError < ApartmentError
  attr_reader :tenant, :original_error

  def initialize(tenant, original_error)
    @tenant = tenant
    @original_error = original_error
    super("Migration failed for tenant '#{tenant}': #{original_error.class}: #{original_error.message}")
  end
end
```

- [ ] **Step 2: Commit**

```bash
git add lib/apartment/errors.rb
git commit -m "Add Apartment::MigrationError for per-tenant migration failures"
```

---

### Task 3: Result and MigrationRun Value Objects

**Files:**
- Create: `lib/apartment/migrator.rb` (partial — just the value objects first)
- Create: `spec/unit/migrator_spec.rb` (partial — result tracking tests)

- [ ] **Step 1: Write failing tests for Result and MigrationRun**

Create `spec/unit/migrator_spec.rb`:

```ruby
# frozen_string_literal: true

require 'spec_helper'
require_relative '../../lib/apartment/migrator'

RSpec.describe(Apartment::Migrator::Result) do
  subject(:result) do
    described_class.new(
      tenant: 'acme',
      status: :success,
      duration: 1.23,
      error: nil,
      versions_run: [20260401000000, 20260402000000]
    )
  end

  it 'is frozen (Data.define)' do
    expect(result).to(be_frozen)
  end

  it 'exposes all attributes' do
    expect(result.tenant).to(eq('acme'))
    expect(result.status).to(eq(:success))
    expect(result.duration).to(eq(1.23))
    expect(result.error).to(be_nil)
    expect(result.versions_run).to(eq([20260401000000, 20260402000000]))
  end
end

RSpec.describe(Apartment::Migrator::MigrationRun) do
  let(:success_result) do
    Apartment::Migrator::Result.new(
      tenant: 'acme', status: :success, duration: 1.0, error: nil, versions_run: [1]
    )
  end
  let(:failed_result) do
    Apartment::Migrator::Result.new(
      tenant: 'broken', status: :failed, duration: 0.5,
      error: StandardError.new('boom'), versions_run: []
    )
  end
  let(:skipped_result) do
    Apartment::Migrator::Result.new(
      tenant: 'current', status: :skipped, duration: 0.01, error: nil, versions_run: []
    )
  end

  subject(:run) do
    described_class.new(
      results: [success_result, failed_result, skipped_result],
      total_duration: 2.5,
      threads: 4
    )
  end

  describe '#succeeded' do
    it 'returns only success results' do
      expect(run.succeeded.map(&:tenant)).to(eq(['acme']))
    end
  end

  describe '#failed' do
    it 'returns only failed results' do
      expect(run.failed.map(&:tenant)).to(eq(['broken']))
    end
  end

  describe '#skipped' do
    it 'returns only skipped results' do
      expect(run.skipped.map(&:tenant)).to(eq(['current']))
    end
  end

  describe '#success?' do
    it 'returns false when there are failures' do
      expect(run.success?).to(be(false))
    end

    it 'returns true when no failures' do
      all_good = described_class.new(
        results: [success_result, skipped_result], total_duration: 1.0, threads: 2
      )
      expect(all_good.success?).to(be(true))
    end
  end

  describe '#summary' do
    it 'includes counts and timing' do
      summary = run.summary
      expect(summary).to(include('3 tenants'))
      expect(summary).to(include('2.5s'))
      expect(summary).to(include('1 succeeded'))
      expect(summary).to(include('1 failed'))
      expect(summary).to(include('1 skipped'))
      expect(summary).to(include('broken'))
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/unit/migrator_spec.rb -v`
Expected: LoadError or NameError (file doesn't exist yet)

- [ ] **Step 3: Implement Result and MigrationRun**

Create `lib/apartment/migrator.rb`:

```ruby
# frozen_string_literal: true

require 'concurrent'
require_relative 'pool_manager'
require_relative 'instrumentation'
require_relative 'errors'

module Apartment
  class Migrator
    Result = Data.define(
      :tenant,
      :status,
      :duration,
      :error,
      :versions_run
    )

    MigrationRun = Data.define(
      :results,
      :total_duration,
      :threads
    ) do
      def succeeded = results.select { _1.status == :success }
      def failed    = results.select { _1.status == :failed }
      def skipped   = results.select { _1.status == :skipped }
      def success?  = failed.empty?

      def summary
        lines = []
        lines << "Migrated #{results.size} tenants in #{total_duration.round(1)}s (#{threads} threads)"
        lines << "  #{succeeded.size} succeeded" if succeeded.any?
        lines << "  #{failed.size} failed: [#{failed.map(&:tenant).join(', ')}]" if failed.any?
        lines << "  #{skipped.size} skipped (up to date)" if skipped.any?
        lines.join("\n")
      end
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/unit/migrator_spec.rb -v`
Expected: All pass

- [ ] **Step 5: Commit**

```bash
git add lib/apartment/migrator.rb spec/unit/migrator_spec.rb
git commit -m "Add Migrator::Result and MigrationRun value objects"
```

---

### Task 4: Migrator Core — Config Resolution and Credential Overlay

**Files:**
- Modify: `lib/apartment/migrator.rb`
- Modify: `spec/unit/migrator_spec.rb`

- [ ] **Step 1: Write failing tests for credential overlay**

Add to `spec/unit/migrator_spec.rb`:

```ruby
RSpec.describe(Apartment::Migrator) do
  before do
    Apartment.configure do |c|
      c.tenant_strategy = :schema
      c.tenants_provider = -> { %w[acme beta] }
      c.default_tenant = 'public'
    end
  end

  describe '#resolve_migration_config' do
    let(:migrator) { described_class.new(threads: 0) }

    it 'returns base config when migration_db_config is nil' do
      # Adapters return string-keyed hashes (via base_config/transform_keys)
      base = { 'adapter' => 'postgresql', 'database' => 'app_db', 'schema_search_path' => 'acme' }
      result = migrator.send(:resolve_migration_config, base, nil)
      expect(result).to(eq(base))
    end

    it 'overlays credentials from migration_db_config' do
      # Base config: string keys (from adapter)
      base = { 'adapter' => 'postgresql', 'database' => 'app_db', 'schema_search_path' => 'acme',
               'username' => 'app_user', 'password' => 'app_pass' }

      # Migration config: symbol keys (from configuration_hash)
      migration_config = { adapter: 'postgresql', database: 'app_db',
                           username: 'db_manager', password: 'mgr_pass' }

      result = migrator.send(:resolve_migration_config, base, migration_config)

      expect(result['username']).to(eq('db_manager'))
      expect(result['password']).to(eq('mgr_pass'))
      expect(result['schema_search_path']).to(eq('acme'))
      expect(result['database']).to(eq('app_db'))
    end

    it 'overlays host when migration config specifies one' do
      base = { 'adapter' => 'postgresql', 'host' => 'app-host', 'username' => 'app' }
      migration_config = { adapter: 'postgresql', host: 'admin-host', username: 'admin', password: 'pass' }

      result = migrator.send(:resolve_migration_config, base, migration_config)
      expect(result['host']).to(eq('admin-host'))
    end
  end

  describe '#initialize' do
    it 'defaults to 0 threads' do
      migrator = described_class.new
      expect(migrator.instance_variable_get(:@threads)).to(eq(0))
    end

    it 'accepts threads parameter' do
      migrator = described_class.new(threads: 8)
      expect(migrator.instance_variable_get(:@threads)).to(eq(8))
    end

    it 'accepts migration_db_config parameter' do
      migrator = described_class.new(migration_db_config: :db_manager)
      expect(migrator.instance_variable_get(:@migration_db_config)).to(eq(:db_manager))
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/unit/migrator_spec.rb -v`
Expected: NoMethodError for `initialize` params and `resolve_migration_config`

- [ ] **Step 3: Implement constructor and credential overlay**

Add to `lib/apartment/migrator.rb` inside the `Migrator` class, after the `MigrationRun` definition:

```ruby
    CREDENTIAL_KEYS = %i[username password host].freeze

    def initialize(threads: 0, migration_db_config: nil)
      @threads = threads
      @migration_db_config = migration_db_config
      @pool_manager = PoolManager.new
    end

    private

    # Overlay migration credentials onto a tenant's base connection config.
    # Only credential keys (username, password, host) are merged; everything
    # else (database, schema_search_path, port, adapter) comes from the base.
    # Note: base_config has string keys (from adapter's base_config/transform_keys),
    # while migration_config has symbol keys (from configuration_hash). We normalize
    # the overlay to string keys before merging.
    def resolve_migration_config(base_config, migration_config)
      return base_config unless migration_config

      overlay = migration_config.slice(*CREDENTIAL_KEYS).compact
      base_config.merge(overlay.transform_keys(&:to_s))
    end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/unit/migrator_spec.rb -v`
Expected: All pass

- [ ] **Step 5: Commit**

```bash
git add lib/apartment/migrator.rb spec/unit/migrator_spec.rb
git commit -m "Migrator: constructor and credential overlay logic"
```

---

### Task 5: Migrator Core — `migrate_tenant` and `#run` (Sequential)

**Files:**
- Modify: `lib/apartment/migrator.rb`
- Modify: `spec/unit/migrator_spec.rb`

- [ ] **Step 1: Write failing tests for migrate_tenant and sequential run**

Add to the `Apartment::Migrator` describe block in `spec/unit/migrator_spec.rb`:

```ruby
  describe '#run' do
    let(:migrator) { described_class.new(threads: 0) }
    let(:mock_adapter) { instance_double('Apartment::Adapters::AbstractAdapter') }
    let(:mock_migration_context) { instance_double('ActiveRecord::MigrationContext') }
    let(:mock_pool) { instance_double('ActiveRecord::ConnectionAdapters::ConnectionPool') }
    let(:mock_connection) { double('connection') }
    let(:mock_schema_migration) { double('schema_migration') }

    before do
      allow(Apartment).to(receive(:adapter).and_return(mock_adapter))
      allow(mock_adapter).to(receive(:resolve_connection_config))
        .with('acme').and_return({ adapter: 'postgresql', schema_search_path: 'acme' })
      allow(mock_adapter).to(receive(:resolve_connection_config))
        .with('beta').and_return({ adapter: 'postgresql', schema_search_path: 'beta' })

      # Stub pool creation and migration context
      allow(ActiveRecord::Base).to(receive(:connection_handler))
        .and_return(double('handler'))
      allow_any_instance_of(PoolManager).to(receive(:fetch_or_create)).and_return(mock_pool)
      allow(mock_pool).to(receive(:with_connection).and_yield(mock_connection))
      allow(mock_pool).to(receive(:schema_migration).and_return(mock_schema_migration))
      allow(mock_pool).to(receive(:migration_context).and_return(mock_migration_context))
      allow(mock_pool).to(receive(:disconnect!))
      allow(mock_migration_context).to(receive(:needs_migration?).and_return(true))
      allow(mock_migration_context).to(receive(:migrate).and_return([]))
    end

    it 'returns a MigrationRun with results for all tenants' do
      result = migrator.run
      expect(result).to(be_a(Apartment::Migrator::MigrationRun))
      expect(result.results.map(&:tenant)).to(contain_exactly('acme', 'beta'))
    end

    it 'returns :skipped for tenants with no pending migrations' do
      allow(mock_migration_context).to(receive(:needs_migration?).and_return(false))
      result = migrator.run
      expect(result.results.map(&:status)).to(all(eq(:skipped)))
    end

    it 'captures errors without halting the run' do
      call_count = 0
      allow(mock_migration_context).to(receive(:migrate)) do
        call_count += 1
        raise(ActiveRecord::StatementInvalid, 'boom') if call_count == 1
        []
      end
      result = migrator.run
      expect(result.failed.size).to(eq(1))
      expect(result.succeeded.size).to(eq(1))
    end

    it 'instruments each tenant migration' do
      expect(Apartment::Instrumentation).to(receive(:instrument)
        .with(:migrate_tenant, hash_including(:tenant)).twice)
      migrator.run
    end

    it 'clears the pool manager after run' do
      expect_any_instance_of(PoolManager).to(receive(:clear))
      migrator.run
    end

    it 'handles empty tenant list' do
      Apartment.configure do |c|
        c.tenant_strategy = :schema
        c.tenants_provider = -> { [] }
        c.default_tenant = 'public'
      end
      result = migrator.run
      # Only the primary result (Phase 1) should be present
      expect(result.results.size).to(eq(1))
    end

    it 'includes primary database result as first entry' do
      result = migrator.run
      expect(result.results.first.tenant).to(eq('public'))
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/unit/migrator_spec.rb -v`
Expected: NoMethodError for `#run`

- [ ] **Step 3: Implement `migrate_tenant` and `#run`**

Add to `lib/apartment/migrator.rb`, in the public section of the class:

```ruby
    def run
      start = monotonic_now

      # Phase 1: Migrate primary database (blocking, before tenants)
      primary_result = migrate_primary
      
      # Phase 2: Migrate tenants
      tenants = Apartment.config.tenants_provider.call
      tenant_results = if @threads > 0
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
      @pool_manager.clear
    end
```

Add to the private section:

```ruby
    # Phase 1: Migrate the primary database (public schema for PG, primary DB for MySQL/SQLite).
    # Uses migration_db_config credentials if configured. Returns nil if no pending migrations.
    def migrate_primary
      start = monotonic_now
      default = Apartment.config.default_tenant || 'public'

      migration_config = resolve_migration_db_config
      config = if migration_config
                 Apartment.adapter.base_config.merge(
                   migration_config.slice(*CREDENTIAL_KEYS).compact.transform_keys(&:to_s)
                 )
               else
                 Apartment.adapter.base_config
               end

      pool = @pool_manager.fetch_or_create("__primary__") { create_pool(config) }
      context = pool.migration_context

      unless context.needs_migration?
        return Result.new(
          tenant: default, status: :skipped, duration: monotonic_now - start,
          error: nil, versions_run: []
        )
      end

      versions = context.migrate
      Instrumentation.instrument(:migrate_tenant, tenant: default, versions: versions)

      Result.new(
        tenant: default, status: :success, duration: monotonic_now - start,
        error: nil, versions_run: Array(versions).map { _1.respond_to?(:version) ? _1.version : _1 }
      )
    rescue StandardError => e
      Instrumentation.instrument(:migrate_tenant, tenant: default, error: e)
      Result.new(
        tenant: default, status: :failed, duration: monotonic_now - start,
        error: e, versions_run: []
      )
    end

    def run_sequential(tenants)
      tenants.map { |tenant| migrate_tenant(tenant) }
    end

    def migrate_tenant(tenant)
      start = monotonic_now

      base_config = Apartment.adapter.resolve_connection_config(tenant)
      migration_config = resolve_migration_db_config
      config = resolve_migration_config(base_config, migration_config)

      pool = @pool_manager.fetch_or_create(tenant) do
        create_pool(config)
      end

      context = pool.migration_context
      unless context.needs_migration?
        return Result.new(
          tenant: tenant, status: :skipped, duration: monotonic_now - start,
          error: nil, versions_run: []
        )
      end

      versions = context.migrate
      Instrumentation.instrument(:migrate_tenant, tenant: tenant, versions: versions)

      Result.new(
        tenant: tenant, status: :success, duration: monotonic_now - start,
        error: nil, versions_run: Array(versions).map { _1.respond_to?(:version) ? _1.version : _1 }
      )
    rescue StandardError => e
      Instrumentation.instrument(:migrate_tenant, tenant: tenant, error: e)
      Result.new(
        tenant: tenant, status: :failed, duration: monotonic_now - start,
        error: e, versions_run: []
      )
    end

    def resolve_migration_db_config
      return nil unless @migration_db_config

      db_config = ActiveRecord::Base.configurations.configs_for(
        env_name: Apartment.config.rails_env_name,
        name: @migration_db_config.to_s
      )
      raise(ConfigurationError, "migration_db_config '#{@migration_db_config}' not found in database.yml") unless db_config

      db_config.configuration_hash
    end

    def create_pool(config)
      # Build a DatabaseConfig and register a pool via AR's ConnectionHandler.
      # This is an ephemeral pool — the Migrator's PoolManager tracks it,
      # and #run ensures cleanup via @pool_manager.clear.
      db_config = ActiveRecord::DatabaseConfigurations::HashConfig.new(
        Apartment.config.rails_env_name,
        "apartment_migrate_#{config[:schema_search_path] || config[:database]}",
        config
      )
      handler = ActiveRecord::Base.connection_handler
      handler.establish_connection(db_config)
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
```

**Implementation notes for `create_pool`:**
- The exact implementation may need adjustment based on how AR's ConnectionHandler works in the target Rails versions. The test stubs this method, so the unit tests validate the orchestration logic independently.
- `establish_connection` registers the pool in AR's global ConnectionHandler. When `@pool_manager.clear` disconnects these pools, the handler still holds stale references. The implementing agent should investigate using a dedicated ConnectionHandler instance (`ActiveRecord::ConnectionAdapters::ConnectionHandler.new`) for the Migrator's pools, or explicitly deregistering pools from the handler during cleanup.

**Deferred from this plan (implement in later tasks or phases):**
- Schema cache per-tenant generation (`schema_cache_per_tenant` config is added but generation logic is not implemented; callers like `release.rb` control cache generation)
- RBAC integration tests (require real `db_manager` role setup in CI)
- Partial failure integration tests (require a way to inject broken migrations per-tenant)

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/unit/migrator_spec.rb -v`
Expected: All pass

- [ ] **Step 5: Commit**

```bash
git add lib/apartment/migrator.rb spec/unit/migrator_spec.rb
git commit -m "Migrator: sequential #run with per-tenant result tracking"
```

---

### Task 6: Migrator Core — Parallel Execution

**Files:**
- Modify: `lib/apartment/migrator.rb`
- Modify: `spec/unit/migrator_spec.rb`

- [ ] **Step 1: Write failing tests for parallel execution**

Add to `spec/unit/migrator_spec.rb`:

```ruby
  describe '#run with threads > 0' do
    let(:migrator) { described_class.new(threads: 4) }

    before do
      allow(Apartment).to(receive(:adapter).and_return(mock_adapter))
      # Stub for 8 tenants to exercise parallelism
      Apartment.configure do |c|
        c.tenant_strategy = :schema
        c.tenants_provider = -> { (1..8).map { |i| "tenant_#{i}" } }
        c.default_tenant = 'public'
      end

      allow(mock_adapter).to(receive(:resolve_connection_config)) do |tenant|
        { adapter: 'postgresql', schema_search_path: tenant }
      end
      allow_any_instance_of(PoolManager).to(receive(:fetch_or_create).and_return(mock_pool))
      allow(mock_pool).to(receive(:migration_context).and_return(mock_migration_context))
      allow(mock_pool).to(receive(:disconnect!))
      allow(mock_migration_context).to(receive(:needs_migration?).and_return(true))
      allow(mock_migration_context).to(receive(:migrate).and_return([]))
      allow(Apartment::Instrumentation).to(receive(:instrument))
      allow_any_instance_of(PoolManager).to(receive(:clear))
    end

    it 'migrates all tenants' do
      result = migrator.run
      expect(result.results.size).to(eq(8))
    end

    it 'records thread count in MigrationRun' do
      result = migrator.run
      expect(result.threads).to(eq(4))
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/unit/migrator_spec.rb -v`
Expected: Failure (run_parallel not implemented)

- [ ] **Step 3: Implement parallel execution**

Add to the private section of `lib/apartment/migrator.rb`:

```ruby
    def run_parallel(tenants)
      work_queue = Queue.new
      tenants.each { |t| work_queue << t }
      @threads.times { work_queue << :done }

      results = Concurrent::Array.new

      workers = @threads.times.map do
        Thread.new do
          while (tenant = work_queue.pop) != :done
            results << migrate_tenant(tenant)
          end
        end
      end

      workers.each(&:join)
      results.to_a
    end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/unit/migrator_spec.rb -v`
Expected: All pass

- [ ] **Step 5: Commit**

```bash
git add lib/apartment/migrator.rb spec/unit/migrator_spec.rb
git commit -m "Migrator: thread-based parallel execution via Queue"
```

---

### Task 7: Schema Dumper Patch

**Files:**
- Create: `lib/apartment/schema_dumper_patch.rb`
- Create: `spec/unit/schema_dumper_patch_spec.rb`

- [ ] **Step 1: Write failing tests for prefix stripping**

Create `spec/unit/schema_dumper_patch_spec.rb`:

```ruby
# frozen_string_literal: true

require 'spec_helper'
require_relative '../../lib/apartment/schema_dumper_patch'

RSpec.describe(Apartment::SchemaDumperPatch) do
  describe '.strip_public_prefix' do
    it 'strips public. prefix from table name' do
      expect(described_class.strip_public_prefix('public.users')).to(eq('users'))
    end

    it 'leaves non-public schemas intact' do
      expect(described_class.strip_public_prefix('extensions.uuid_ossp')).to(eq('extensions.uuid_ossp'))
    end

    it 'leaves unqualified names unchanged' do
      expect(described_class.strip_public_prefix('users')).to(eq('users'))
    end

    it 'respects include_schemas_in_dump' do
      # When 'shared' is in include list, shared.foo stays as-is
      expect(described_class.strip_public_prefix('shared.lookups', include_schemas: %w[shared]))
        .to(eq('shared.lookups'))
    end

    it 'strips public. even when include_schemas is set' do
      expect(described_class.strip_public_prefix('public.users', include_schemas: %w[shared]))
        .to(eq('users'))
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/unit/schema_dumper_patch_spec.rb -v`
Expected: LoadError (file doesn't exist)

- [ ] **Step 3: Implement the patch**

Create `lib/apartment/schema_dumper_patch.rb`:

```ruby
# frozen_string_literal: true

module Apartment
  # Patches ActiveRecord::SchemaDumper to strip 'public.' prefix from table
  # names in schema.rb output. Applied conditionally for Rails 8.1+ where
  # schema-qualified table names were introduced.
  #
  # This ensures schema.rb can be loaded into any PostgreSQL schema without
  # tables being created in 'public' instead of the target schema.
  module SchemaDumperPatch
    def self.strip_public_prefix(table_name, include_schemas: [])
      schema, name = table_name.split('.', 2)

      # No schema qualifier — return as-is
      return table_name unless name

      # Non-public schema that's in the include list — keep qualified
      return table_name if schema != 'public' && include_schemas.include?(schema)

      # Public schema — strip prefix
      return name if schema == 'public'

      # Non-public schema not in include list — keep qualified
      table_name
    end

    def self.apply!
      return unless should_patch?

      ActiveRecord::SchemaDumper.prepend(DumperOverride)
    end

    def self.should_patch?
      return false unless defined?(ActiveRecord::SchemaDumper)

      ActiveRecord.gem_version >= Gem::Version.new('8.1.0')
    end

    module DumperOverride
      private

      def table(table_name, stream)
        include_schemas = Apartment.config&.postgres_config&.include_schemas_in_dump || []
        stripped = SchemaDumperPatch.strip_public_prefix(table_name, include_schemas: include_schemas)
        super(stripped, stream)
      end
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/unit/schema_dumper_patch_spec.rb -v`
Expected: All pass

- [ ] **Step 5: Commit**

```bash
git add lib/apartment/schema_dumper_patch.rb spec/unit/schema_dumper_patch_spec.rb
git commit -m "Schema dumper patch: strip public. prefix for Rails 8.1+"
```

---

### Task 8: Wire Rake Tasks Through Migrator

**Files:**
- Modify: `lib/apartment/tasks/v4.rake:24-58`

- [ ] **Step 1: Write the updated rake tasks**

Replace the `apartment:migrate` and `apartment:rollback` tasks in `lib/apartment/tasks/v4.rake`:

```ruby
desc 'Run migrations for all tenants'
task migrate: :environment do
  require 'apartment/migrator'

  threads = Apartment.config.parallel_migration_threads
  migration_db_config = Apartment.config.migration_db_config

  migrator = Apartment::Migrator.new(
    threads: threads,
    migration_db_config: migration_db_config
  )

  result = migrator.run
  puts result.summary

  unless result.success?
    abort "apartment:migrate failed for #{result.failed.size} tenant(s)"
  end

  # Schema dump (respects ActiveRecord.dump_schema_after_migration)
  if ActiveRecord.dump_schema_after_migration
    Rake::Task['db:schema:dump'].invoke if Rake::Task.task_defined?('db:schema:dump')
  end
end

desc 'Rollback migrations for all tenants'
task :rollback, [:step] => :environment do |_t, args|
  step = (args[:step] || 1).to_i
  tenants = Apartment.config.tenants_provider.call
  tenants.each do |tenant|
    puts "Rolling back tenant: #{tenant} (#{step} step(s))"
    Apartment::Tenant.switch(tenant) do
      ActiveRecord::Base.connection_pool.migration_context.rollback(step)
    end
  rescue StandardError => e
    warn "  FAILED: #{e.message}"
  end
end
```

Note: `apartment:rollback` remains sequential (rollback is a rare, careful operation). Only `apartment:migrate` gets the Migrator.

- [ ] **Step 2: Run existing tests**

Run: `bundle exec rspec spec/unit/ -v`
Expected: All pass (rake tasks aren't unit-tested directly; they're validated via integration)

- [ ] **Step 3: Commit**

```bash
git add lib/apartment/tasks/v4.rake
git commit -m "Rake: wire apartment:migrate through Migrator with parallel support"
```

---

### Task 9: Railtie Enhancement — `db:migrate:DBNAME` Hook

**Files:**
- Modify: `lib/apartment/railtie.rb:46-48`

- [ ] **Step 1: Add the enhancement hook**

In `lib/apartment/railtie.rb`, expand the `rake_tasks` block:

```ruby
rake_tasks do
  load File.expand_path('tasks/v4.rake', __dir__)

  # Enhance db:migrate:DBNAME to also run apartment:migrate.
  # Uses Rake's enhance to append apartment:migrate after the primary
  # database migration completes. Wrapped in begin/rescue to handle
  # cases where the database doesn't exist yet (db:create).
  begin
    primary_db_name = ActiveRecord::Base.configurations
      .configs_for(env_name: Rails.env)
      .find { |c| c.name == 'primary' }
      &.name || 'primary'

    if Rake::Task.task_defined?("db:migrate:#{primary_db_name}")
      Rake::Task["db:migrate:#{primary_db_name}"].enhance do
        Rake::Task['apartment:migrate'].invoke if Rake::Task.task_defined?('apartment:migrate')
      end
    end
  rescue ActiveRecord::NoDatabaseError
    # Database doesn't exist yet (e.g., during db:create). Skip enhancement.
  end
end
```

- [ ] **Step 2: Verify no regressions**

Run: `bundle exec rspec spec/unit/ -v`
Expected: All pass

- [ ] **Step 3: Commit**

```bash
git add lib/apartment/railtie.rb
git commit -m "Railtie: enhance db:migrate:DBNAME to trigger apartment:migrate"
```

---

### Task 10: Schema Dumper Patch Activation in Railtie

**Files:**
- Modify: `lib/apartment/railtie.rb`

- [ ] **Step 1: Apply schema dumper patch during Rails init**

In the `config.after_initialize` block in `lib/apartment/railtie.rb`, after `Apartment.activate!`:

```ruby
# Apply schema dumper patch for Rails 8.1+ (public. prefix stripping)
require 'apartment/schema_dumper_patch'
Apartment::SchemaDumperPatch.apply!
```

- [ ] **Step 2: Commit**

```bash
git add lib/apartment/railtie.rb
git commit -m "Railtie: activate schema dumper patch on Rails 8.1+"
```

---

### Task 11: Integration Tests

**Files:**
- Create: `spec/integration/v4/migrator_integration_spec.rb`

- [ ] **Step 1: Write integration tests**

Create `spec/integration/v4/migrator_integration_spec.rb`. This test requires a real database (PostgreSQL or SQLite). Follow the pattern from `spec/integration/v4/tenant_lifecycle_spec.rb`:

```ruby
# frozen_string_literal: true

require_relative 'support'

RSpec.describe('Migrator integration', :v4_integration) do
  include V4IntegrationHelper

  before do
    establish_default_connection!
    Apartment.configure do |c|
      c.tenant_strategy = detect_strategy
      c.tenants_provider = -> { %w[migrate_a migrate_b migrate_c] }
      c.default_tenant = detect_default_tenant
      c.parallel_migration_threads = 0
    end
    Apartment.activate!
    @adapter = build_adapter
    %w[migrate_a migrate_b migrate_c].each { |t| safe_create_tenant(t) }
  end

  after do
    cleanup_tenants!(%w[migrate_a migrate_b migrate_c])
    clear_config
  end

  describe 'sequential migration' do
    it 'migrates all tenants and returns MigrationRun' do
      migrator = Apartment::Migrator.new(threads: 0)
      result = migrator.run

      expect(result).to(be_a(Apartment::Migrator::MigrationRun))
      expect(result.results.size).to(eq(3))
      expect(result.threads).to(eq(0))
    end
  end

  describe 'parallel migration' do
    it 'migrates all tenants with threads' do
      migrator = Apartment::Migrator.new(threads: 2)
      result = migrator.run

      expect(result.results.size).to(eq(3))
      tenants = result.results.map(&:tenant)
      expect(tenants).to(contain_exactly('migrate_a', 'migrate_b', 'migrate_c'))
    end
  end

  describe 'idempotency' do
    it 'returns :skipped on second run' do
      Apartment::Migrator.new(threads: 0).run
      result = Apartment::Migrator.new(threads: 0).run

      expect(result.results.map(&:status)).to(all(eq(:skipped)))
    end
  end
end
```

Note: The exact helper methods (`establish_default_connection!`, `build_adapter`, `safe_create_tenant`, `cleanup_tenants!`, `clear_config`, `detect_strategy`, `detect_default_tenant`) follow the patterns in `spec/integration/v4/support.rb`. The implementation agent should read that file and adapt.

- [ ] **Step 2: Run integration tests**

Run: `bundle exec appraisal rails-8.1-sqlite3 rspec spec/integration/v4/migrator_integration_spec.rb -v`
Expected: All pass

- [ ] **Step 3: Commit**

```bash
git add spec/integration/v4/migrator_integration_spec.rb
git commit -m "Integration tests for Migrator (sequential, parallel, idempotency)"
```

---

### Task 12: Update CLAUDE.md Files

**Files:**
- Modify: `lib/apartment/CLAUDE.md`
- Modify: `lib/apartment/tasks/CLAUDE.md`

- [ ] **Step 1: Update lib/apartment/CLAUDE.md**

Add `migrator.rb` and `schema_dumper_patch.rb` entries to the directory structure and file descriptions. Add the Migrator to the data flow section.

- [ ] **Step 2: Update lib/apartment/tasks/CLAUDE.md**

Note that `apartment:migrate` now delegates to `Apartment::Migrator` with parallel support.

- [ ] **Step 3: Commit**

```bash
git add lib/apartment/CLAUDE.md lib/apartment/tasks/CLAUDE.md
git commit -m "Update CLAUDE.md docs for Migrator and schema dumper patch"
```

---

### Task 13: Full Test Suite Verification

- [ ] **Step 1: Run full unit suite**

Run: `bundle exec rspec spec/unit/ -v`
Expected: All pass

- [ ] **Step 2: Run unit suite across Rails versions**

Run: `bundle exec appraisal rspec spec/unit/`
Expected: All pass across all appraisal targets

- [ ] **Step 3: Run integration tests (SQLite)**

Run: `bundle exec appraisal rails-8.1-sqlite3 rspec spec/integration/v4/`
Expected: All pass

- [ ] **Step 4: Run integration tests (PostgreSQL)**

Run: `DATABASE_ENGINE=postgresql bundle exec appraisal rails-8.1-postgresql rspec spec/integration/v4/`
Expected: All pass

- [ ] **Step 5: Run lint**

Run: `bundle exec rubocop lib/apartment/migrator.rb lib/apartment/schema_dumper_patch.rb`
Expected: No offenses

- [ ] **Step 6: Final commit if any fixes needed**

```bash
git add <specific-files-that-changed> && git commit -m "Fix lint/test issues from full suite verification"
```
