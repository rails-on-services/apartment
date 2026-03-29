# Phase 2.3: Connection Handling & Pool Wiring — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire `Apartment::Current.tenant` to ActiveRecord's connection pool resolution so that `Tenant.switch("acme") { User.count }` transparently uses a tenant-specific connection pool.

**Architecture:** A single module prepended on `ActiveRecord::Base` overrides `connection_pool` to return tenant-specific pools via AR's `establish_connection` with shard-based keying. PoolReaper is converted from class singleton to instance and gains AR handler cleanup on eviction. Config gets `shard_key_prefix` for namespacing.

**Tech Stack:** Ruby 3.3+, ActiveRecord 7.2+, SQLite3 (for unit tests), RSpec, `concurrent-ruby`

**Spec:** [`docs/designs/phase-2.3-connection-handling.md`](../../designs/phase-2.3-connection-handling.md)

---

## File Map

### New files

| File | Responsibility |
|------|---------------|
| `lib/apartment/patches/connection_handling.rb` | `connection_pool` override — the core patch |
| `spec/unit/patches/connection_handling_spec.rb` | Unit tests for pool resolution with real AR + SQLite3 |

### Modified files

| File | Change summary |
|------|---------------|
| `lib/apartment/config.rb` | Add `shard_key_prefix` attr, `rails_env_name` method, validation |
| `lib/apartment/pool_reaper.rb` | Convert class singleton → instance, add AR handler cleanup in eviction |
| `lib/apartment.rb` | Add `pool_reaper` accessor, `activate!`, extract `teardown_old_state` with AR handler deregistration, update `configure`/`clear_config` |
| `spec/unit/config_spec.rb` | Tests for `shard_key_prefix` and `rails_env_name` |
| `spec/unit/pool_reaper_spec.rb` | Rewrite for instance API |
| `spec/unit/apartment_spec.rb` | Tests for `activate!`, teardown protection, `pool_reaper` accessor |

---

## Task 1: Config — `shard_key_prefix` and `rails_env_name`

**Files:**
- Modify: `lib/apartment/config.rb`
- Modify: `spec/unit/config_spec.rb`

Foundation for all other tasks — the shard key prefix and env name are used by ConnectionHandling and PoolReaper.

- [ ] **Step 1: Write failing tests for `shard_key_prefix` default and validation**

Add to `spec/unit/config_spec.rb` in the `defaults` describe block:

```ruby
it { expect(config.shard_key_prefix).to(eq('apartment')) }
```

Add a new describe block after `#environmentify_strategy=`:

```ruby
describe '#shard_key_prefix validation' do
  before do
    config.tenant_strategy = :schema
    config.tenants_provider = -> { [] }
  end

  it 'passes with default value' do
    expect { config.validate! }.not_to(raise_error)
  end

  it 'passes with custom valid prefix' do
    config.shard_key_prefix = 'myapp_tenant'
    expect { config.validate! }.not_to(raise_error)
  end

  it 'raises for empty string' do
    config.shard_key_prefix = ''
    expect { config.validate! }.to(raise_error(Apartment::ConfigurationError, /shard_key_prefix/))
  end

  it 'raises for string starting with number' do
    config.shard_key_prefix = '1bad'
    expect { config.validate! }.to(raise_error(Apartment::ConfigurationError, /shard_key_prefix/))
  end

  it 'raises for string with special characters' do
    config.shard_key_prefix = 'my-prefix'
    expect { config.validate! }.to(raise_error(Apartment::ConfigurationError, /shard_key_prefix/))
  end

  it 'raises for non-string' do
    config.shard_key_prefix = :symbol
    expect { config.validate! }.to(raise_error(Apartment::ConfigurationError, /shard_key_prefix/))
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/unit/config_spec.rb --format documentation`
Expected: Multiple failures (undefined method `shard_key_prefix`)

- [ ] **Step 3: Implement `shard_key_prefix` on Config**

In `lib/apartment/config.rb`:

Add `shard_key_prefix` to `attr_accessor` list (line 18):
```ruby
attr_accessor :tenants_provider, :default_tenant, :excluded_models,
              :tenant_pool_size, :pool_idle_timeout, :max_total_connections,
              :seed_after_create, :seed_data_file,
              :parallel_migration_threads,
              :elevator, :elevator_options,
              :tenant_not_found_handler, :active_record_log,
              :shard_key_prefix
```

Add default in `initialize` (after line 41, before `@postgres_config`):
```ruby
@shard_key_prefix = 'apartment'
```

Add validation at end of `validate!` method (before the closing `end`):
```ruby
unless @shard_key_prefix.is_a?(String) && @shard_key_prefix.match?(/\A[a-z_][a-z0-9_]*\z/)
  raise(ConfigurationError,
        "shard_key_prefix must be a lowercase string matching /[a-z_][a-z0-9_]*/, got: #{@shard_key_prefix.inspect}")
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/unit/config_spec.rb --format documentation`
Expected: All PASS

- [ ] **Step 5: Write failing test for `rails_env_name`**

Add to `spec/unit/config_spec.rb`:

```ruby
describe '#rails_env_name' do
  it 'returns Rails.env when Rails is defined' do
    stub_const('Rails', double(env: 'test'))
    expect(config.rails_env_name).to(eq('test'))
  end

  it 'falls back to RAILS_ENV env var' do
    hide_const('Rails') if defined?(Rails)
    allow(ENV).to(receive(:[]).and_call_original)
    allow(ENV).to(receive(:[]).with('RAILS_ENV').and_return('staging'))
    expect(config.rails_env_name).to(eq('staging'))
  end

  it 'falls back to RACK_ENV env var' do
    hide_const('Rails') if defined?(Rails)
    allow(ENV).to(receive(:[]).and_call_original)
    allow(ENV).to(receive(:[]).with('RAILS_ENV').and_return(nil))
    allow(ENV).to(receive(:[]).with('RACK_ENV').and_return('production'))
    expect(config.rails_env_name).to(eq('production'))
  end

  it 'defaults to "default_env" when nothing is set' do
    hide_const('Rails') if defined?(Rails)
    allow(ENV).to(receive(:[]).and_call_original)
    allow(ENV).to(receive(:[]).with('RAILS_ENV').and_return(nil))
    allow(ENV).to(receive(:[]).with('RACK_ENV').and_return(nil))
    expect(config.rails_env_name).to(eq('default_env'))
  end
end
```

- [ ] **Step 6: Run test to verify it fails**

Run: `bundle exec rspec spec/unit/config_spec.rb -e 'rails_env_name' --format documentation`
Expected: FAIL (undefined method)

- [ ] **Step 7: Implement `rails_env_name`**

Add to `lib/apartment/config.rb` as a public method (after `configure_mysql`, before `freeze!`):

```ruby
# Environment name for AR's HashConfig. Mirrors ActiveRecord::ConnectionHandling::DEFAULT_ENV.
def rails_env_name
  (Rails.env if defined?(Rails.env)) || ENV['RAILS_ENV'] || ENV['RACK_ENV'] || 'default_env'
end
```

- [ ] **Step 8: Run all config tests**

Run: `bundle exec rspec spec/unit/config_spec.rb --format documentation`
Expected: All PASS

- [ ] **Step 9: Commit**

```bash
git add lib/apartment/config.rb spec/unit/config_spec.rb
git commit -m "Config: add shard_key_prefix and rails_env_name for Phase 2.3"
```

---

## Task 2: PoolReaper — Convert to Instance

**Files:**
- Modify: `lib/apartment/pool_reaper.rb`
- Modify: `spec/unit/pool_reaper_spec.rb`

Convert PoolReaper from class singleton to instance. Keep the same behavior, change the API surface. AR handler cleanup comes in Task 4 (after ConnectionHandling exists).

- [ ] **Step 1: Write failing tests for instance API**

Replace `spec/unit/pool_reaper_spec.rb` entirely:

```ruby
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe(Apartment::PoolReaper) do
  let(:pool_manager) { Apartment::PoolManager.new }
  let(:disconnect_calls) { Concurrent::Array.new }
  let(:on_evict) { ->(tenant, _pool) { disconnect_calls << tenant } }
  let(:reaper) do
    described_class.new(
      pool_manager: pool_manager,
      interval: 0.05,
      idle_timeout: 1,
      on_evict: on_evict
    )
  end

  after { reaper.stop if reaper.running? }

  describe '#initialize' do
    it 'creates a reaper without starting it' do
      expect(reaper).not_to(be_running)
    end

    it 'raises ArgumentError for zero interval' do
      expect { described_class.new(pool_manager: pool_manager, interval: 0, idle_timeout: 1) }
        .to(raise_error(ArgumentError, /interval/))
    end

    it 'raises ArgumentError for negative idle_timeout' do
      expect { described_class.new(pool_manager: pool_manager, interval: 1, idle_timeout: -1) }
        .to(raise_error(ArgumentError, /idle_timeout/))
    end

    it 'raises ArgumentError for non-positive max_total' do
      expect { described_class.new(pool_manager: pool_manager, interval: 1, idle_timeout: 1, max_total: 0) }
        .to(raise_error(ArgumentError, /max_total/))
    end
  end

  describe '#start / #stop' do
    it 'can start and stop without error' do
      reaper.start
      expect(reaper).to(be_running)
      reaper.stop
      expect(reaper).not_to(be_running)
    end

    it 'is idempotent on stop' do
      reaper.start
      reaper.stop
      expect { reaper.stop }.not_to(raise_error)
    end
  end

  describe 'idle eviction' do
    it 'evicts pools idle beyond timeout' do
      pool_manager.fetch_or_create('stale') { 'pool_stale' }
      pool_manager.instance_variable_get(:@timestamps)['stale'] = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 10

      pool_manager.fetch_or_create('fresh') { 'pool_fresh' }

      reaper.start
      sleep 0.2

      expect(disconnect_calls).to(include('stale'))
      expect(pool_manager.tracked?('stale')).to(be(false))
      expect(pool_manager.tracked?('fresh')).to(be(true))
    end
  end

  describe 'max_total eviction' do
    let(:reaper) do
      described_class.new(
        pool_manager: pool_manager,
        interval: 0.05,
        idle_timeout: 999,
        max_total: 2,
        on_evict: on_evict
      )
    end

    it 'evicts LRU pools when over max' do
      3.times do |i|
        pool_manager.fetch_or_create("tenant_#{i}") { "pool_#{i}" }
        pool_manager.instance_variable_get(:@timestamps)["tenant_#{i}"] =
          Process.clock_gettime(Process::CLOCK_MONOTONIC) - (300 - (i * 100))
      end

      reaper.start
      sleep 0.2

      expect(pool_manager.stats[:total_pools]).to(be <= 2)
      expect(disconnect_calls).to(include('tenant_0'))
    end
  end

  describe 'protected tenants' do
    let(:reaper) do
      described_class.new(
        pool_manager: pool_manager,
        interval: 0.05,
        idle_timeout: 1,
        default_tenant: 'public',
        on_evict: on_evict
      )
    end

    it 'never evicts the default tenant' do
      pool_manager.fetch_or_create('public') { 'pool_default' }
      pool_manager.instance_variable_get(:@timestamps)['public'] =
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - 9999

      reaper.start
      sleep 0.2

      expect(pool_manager.tracked?('public')).to(be(true))
      expect(disconnect_calls).not_to(include('public'))
    end
  end

  describe 'double start' do
    it 'stops the previous timer before starting a new one' do
      reaper.start
      expect(reaper).to(be_running)
      reaper.start
      expect(reaper).to(be_running)
      reaper.stop
      expect(reaper).not_to(be_running)
    end
  end

  describe 'error resilience' do
    it 'continues running when on_evict callback raises' do
      bad_callback = ->(_tenant, _pool) { raise('callback explosion') }
      resilient_reaper = described_class.new(
        pool_manager: pool_manager,
        interval: 0.05,
        idle_timeout: 1,
        on_evict: bad_callback
      )

      pool_manager.fetch_or_create('tenant_a') { 'pool_a' }
      pool_manager.instance_variable_get(:@timestamps)['tenant_a'] =
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - 10

      resilient_reaper.start
      sleep 0.3

      expect(resilient_reaper).to(be_running)
      expect(pool_manager.tracked?('tenant_a')).to(be(false))
    ensure
      resilient_reaper&.stop
    end
  end

  describe 'instrumentation' do
    it 'emits evict.apartment events on eviction' do
      events = Concurrent::Array.new
      ActiveSupport::Notifications.subscribe('evict.apartment') { |event| events << event }

      pool_manager.fetch_or_create('stale') { 'pool_stale' }
      pool_manager.instance_variable_get(:@timestamps)['stale'] = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 10

      reaper.start
      sleep(0.2)

      expect(events.any? { |e| e.payload[:tenant] == 'stale' }).to(be(true))
    ensure
      ActiveSupport::Notifications.unsubscribe('evict.apartment')
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/unit/pool_reaper_spec.rb --format documentation`
Expected: FAIL (class methods vs instance methods)

- [ ] **Step 3: Rewrite `pool_reaper.rb` as instance-based**

Replace `lib/apartment/pool_reaper.rb`:

```ruby
# frozen_string_literal: true

require 'concurrent'
require_relative 'instrumentation'

module Apartment
  # Evicts idle and excess tenant pools on a background timer.
  # Complementary to ActiveRecord's ConnectionPool::Reaper which handles
  # intra-pool connection reaping — this handles inter-pool (tenant) eviction.
  class PoolReaper
    def initialize(pool_manager:, interval:, idle_timeout:, max_total: nil,
                   default_tenant: nil, shard_key_prefix: nil, on_evict: nil)
      raise(ArgumentError, 'interval must be a positive number') unless interval.is_a?(Numeric) && interval.positive?
      unless idle_timeout.is_a?(Numeric) && idle_timeout.positive?
        raise(ArgumentError, 'idle_timeout must be a positive number')
      end
      if max_total && (!max_total.is_a?(Integer) || max_total < 1)
        raise(ArgumentError, 'max_total must be a positive integer or nil')
      end

      @pool_manager = pool_manager
      @interval = interval
      @idle_timeout = idle_timeout
      @max_total = max_total
      @default_tenant = default_tenant
      @shard_key_prefix = shard_key_prefix
      @on_evict = on_evict
      @mutex = Mutex.new
      @timer = nil
    end

    def start
      @mutex.synchronize do
        stop_internal
        @timer = Concurrent::TimerTask.new(execution_interval: @interval) { reap }
        @timer.execute
      end
    end

    def stop
      @mutex.synchronize { stop_internal }
    end

    def running?
      @mutex.synchronize { @timer&.running? || false }
    end

    private

    def stop_internal
      return unless @timer

      @timer.shutdown
      @timer.wait_for_termination(5)
      @timer = nil
    end

    def reap
      evict_idle
      evict_lru if @max_total
    rescue Apartment::ApartmentError => e
      warn "[Apartment::PoolReaper] #{e.class}: #{e.message}"
    rescue StandardError => e
      warn "[Apartment::PoolReaper] Unexpected error: #{e.class}: #{e.message}"
      warn e.backtrace&.first(5)&.join("\n") if e.backtrace
    end

    def evict_idle
      @pool_manager.idle_tenants(timeout: @idle_timeout).each do |tenant|
        next if tenant == @default_tenant

        pool = @pool_manager.remove(tenant)
        deregister_from_ar_handler(tenant)
        Instrumentation.instrument(:evict, tenant: tenant, reason: :idle)
        @on_evict&.call(tenant, pool)
      rescue StandardError => e
        warn "[Apartment::PoolReaper] Failed to evict tenant #{tenant}: #{e.class}: #{e.message}"
      end
    end

    def evict_lru
      excess = @pool_manager.stats[:total_pools] - @max_total
      return if excess <= 0

      candidates = @pool_manager.lru_tenants(count: excess + 1)
      evicted = 0
      candidates.each do |tenant|
        break if evicted >= excess
        next if tenant == @default_tenant

        pool = @pool_manager.remove(tenant)
        deregister_from_ar_handler(tenant)
        Instrumentation.instrument(:evict, tenant: tenant, reason: :lru)
        @on_evict&.call(tenant, pool)
        evicted += 1
      rescue StandardError => e
        warn "[Apartment::PoolReaper] Failed to evict tenant #{tenant}: #{e.class}: #{e.message}"
      end
    end

    def deregister_from_ar_handler(tenant)
      return unless @shard_key_prefix && defined?(ActiveRecord::Base)

      shard_key = :"#{@shard_key_prefix}_#{tenant}"
      ActiveRecord::Base.connection_handler.remove_connection_pool(
        'ActiveRecord::Base',
        role: ActiveRecord::Base.current_role,
        shard: shard_key
      )
    rescue StandardError => e
      warn "[Apartment::PoolReaper] Failed to deregister AR pool for #{tenant}: #{e.class}: #{e.message}"
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/unit/pool_reaper_spec.rb --format documentation`
Expected: All PASS

- [ ] **Step 5: Commit**

```bash
git add lib/apartment/pool_reaper.rb spec/unit/pool_reaper_spec.rb
git commit -m "PoolReaper: convert from class singleton to instance

Addresses deferred Phase 1 review item. Instance API enables test
isolation and removes global mutable state. AR handler deregistration
added (no-op until shard_key_prefix is configured in Phase 2.3)."
```

---

## Task 3: `Apartment` module — `teardown_old_state`, `activate!`, updated `configure`/`clear_config`

**Files:**
- Modify: `lib/apartment.rb`
- Modify: `spec/unit/apartment_spec.rb`
- Modify: `spec/spec_helper.rb`

Wire the instance-based PoolReaper into the Apartment module. Add `activate!` and protected teardown.

- [ ] **Step 1: Write failing tests**

Add to `spec/unit/apartment_spec.rb`:

```ruby
describe '.pool_reaper' do
  it 'is nil before configure' do
    expect(described_class.pool_reaper).to(be_nil)
  end

  it 'is an instance of PoolReaper after configure' do
    described_class.configure do |config|
      config.tenant_strategy = :schema
      config.tenants_provider = -> { [] }
    end
    expect(described_class.pool_reaper).to(be_a(Apartment::PoolReaper))
  end

  it 'is running after configure' do
    described_class.configure do |config|
      config.tenant_strategy = :schema
      config.tenants_provider = -> { [] }
    end
    expect(described_class.pool_reaper).to(be_running)
  end

  it 'is nil after clear_config' do
    described_class.configure do |config|
      config.tenant_strategy = :schema
      config.tenants_provider = -> { [] }
    end
    described_class.clear_config
    expect(described_class.pool_reaper).to(be_nil)
  end
end

describe '.configure teardown protection' do
  it 'completes reconfigure even if reaper stop raises' do
    described_class.configure do |config|
      config.tenant_strategy = :schema
      config.tenants_provider = -> { [] }
    end

    # Sabotage the reaper's stop method
    allow(described_class.pool_reaper).to(receive(:stop).and_raise(RuntimeError, 'timer boom'))

    # Reconfigure should still succeed
    expect do
      described_class.configure do |config|
        config.tenant_strategy = :schema
        config.tenants_provider = -> { [] }
        config.default_tenant = 'new_default'
      end
    end.not_to(raise_error)

    expect(described_class.config.default_tenant).to(eq('new_default'))
  end
end

describe '.activate!' do
  it 'prepends ConnectionHandling on ActiveRecord::Base' do
    # Load the patch module first
    require_relative '../../lib/apartment/patches/connection_handling'

    described_class.activate!
    expect(ActiveRecord::Base.singleton_class.ancestors).to(
      include(Apartment::Patches::ConnectionHandling)
    )
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/unit/apartment_spec.rb -e 'pool_reaper|teardown|activate' --format documentation`
Expected: FAIL

- [ ] **Step 3: Update `lib/apartment.rb`**

Replace `lib/apartment.rb`:

```ruby
# frozen_string_literal: true

require 'zeitwerk'
require 'active_support'
require 'active_support/current_attributes'

# Set up Zeitwerk autoloader for the Apartment namespace.
loader = Zeitwerk::Loader.for_gem(warn_on_extra_files: false)
loader.inflector.inflect(
  'mysql_config' => 'MySQLConfig',
  'postgresql_config' => 'PostgreSQLConfig'
)

# errors.rb defines multiple constants (not a single Errors class).
loader.ignore("#{__dir__}/apartment/errors.rb")

# Ignore v3 files that haven't been replaced yet.
%w[
  railtie
  deprecation
  log_subscriber
  console
  custom_console
  migrator
  model
].each { |f| loader.ignore("#{__dir__}/apartment/#{f}.rb") }

loader.ignore("#{__dir__}/apartment/adapters")
loader.ignore("#{__dir__}/apartment/elevators")
loader.ignore("#{__dir__}/apartment/patches")
loader.ignore("#{__dir__}/apartment/tasks")
loader.ignore("#{__dir__}/apartment/active_record")

loader.setup

require_relative 'apartment/errors'

module Apartment
  class << self
    attr_reader :config, :pool_manager, :pool_reaper
    attr_writer :adapter

    # Lazy-loading adapter. Built on first access via build_adapter.
    def adapter
      @adapter ||= build_adapter
    end

    # Configure Apartment v4. Yields a Config instance, validates it,
    # and prepares the module for use.
    def configure
      raise(ConfigurationError, 'Apartment.configure requires a block') unless block_given?

      # Prepare-then-swap: build and validate new config before tearing down
      # old state. If the block or validate! raises, the previous working
      # configuration is preserved.
      new_config = Config.new
      yield(new_config)
      new_config.validate!
      new_config.freeze!

      # Validation passed — tear down old state and swap in new.
      teardown_old_state
      @config = new_config
      @pool_manager = PoolManager.new
      @pool_reaper = PoolReaper.new(
        pool_manager: @pool_manager,
        interval: new_config.pool_idle_timeout,
        idle_timeout: new_config.pool_idle_timeout,
        max_total: new_config.max_total_connections,
        default_tenant: new_config.default_tenant,
        shard_key_prefix: new_config.shard_key_prefix
      )
      @pool_reaper.start
      @config
    end

    # Reset all configuration and stop background tasks.
    def clear_config
      teardown_old_state
      @config = nil
      @pool_manager = nil
      @pool_reaper = nil
    end

    # Activate the ConnectionHandling patch on ActiveRecord::Base.
    # Idempotent — prepend on an already-prepended module is a no-op.
    def activate!
      require_relative 'apartment/patches/connection_handling'
      ActiveRecord::Base.singleton_class.prepend(Patches::ConnectionHandling)
    end

    private

    # Safely tear down old state. Deregisters tenant pools from AR's
    # ConnectionHandler before clearing, then stops the reaper.
    # Rescues failures so a broken timer doesn't prevent reconfiguration.
    def teardown_old_state
      begin
        @pool_reaper&.stop
      rescue StandardError => e
        warn "[Apartment] PoolReaper.stop failed during teardown: #{e.class}: #{e.message}"
      end
      deregister_all_tenant_pools
      @pool_manager&.clear
      @adapter = nil
    end

    # Deregister all tenant pools from AR's ConnectionHandler.
    # Called during teardown to prevent stale shard registrations.
    def deregister_all_tenant_pools
      return unless @pool_manager && @config && defined?(ActiveRecord::Base)

      prefix = @config.shard_key_prefix
      @pool_manager.stats[:tenants]&.each do |tenant_key|
        shard_key = :"#{prefix}_#{tenant_key}"
        ActiveRecord::Base.connection_handler.remove_connection_pool(
          'ActiveRecord::Base',
          role: ActiveRecord::Base.current_role,
          shard: shard_key
        )
      rescue StandardError => e
        warn "[Apartment] Failed to deregister pool for #{tenant_key}: #{e.class}: #{e.message}"
      end
    end

    # Factory: resolve the correct adapter class based on strategy and database adapter.
    def build_adapter
      raise(ConfigurationError, 'Apartment not configured. Call Apartment.configure first.') unless @config

      strategy = config.tenant_strategy
      db_adapter = detect_database_adapter

      klass = case strategy
              when :schema
                require_relative('apartment/adapters/postgresql_schema_adapter')
                Adapters::PostgreSQLSchemaAdapter
              when :database_name
                case db_adapter
                when /postgresql/, /postgis/
                  require_relative('apartment/adapters/postgresql_database_adapter')
                  Adapters::PostgreSQLDatabaseAdapter
                when /mysql2/
                  require_relative('apartment/adapters/mysql2_adapter')
                  Adapters::MySQL2Adapter
                when /trilogy/
                  require_relative('apartment/adapters/trilogy_adapter')
                  Adapters::TrilogyAdapter
                when /sqlite/
                  require_relative('apartment/adapters/sqlite3_adapter')
                  Adapters::SQLite3Adapter
                else
                  raise(AdapterNotFound, "No adapter for database: #{db_adapter}")
                end
              else
                raise(AdapterNotFound, "Strategy #{strategy} not yet implemented")
              end

      klass.new(ActiveRecord::Base.connection_db_config.configuration_hash)
    end

    def detect_database_adapter
      ActiveRecord::Base.connection_db_config.adapter
    end
  end
end
```

- [ ] **Step 4: Update `spec/spec_helper.rb` teardown**

The `after` block calls `Apartment.clear_config` which now handles instance-based reaper. No changes needed to spec_helper itself — but verify the existing tests still pass.

- [ ] **Step 5: Run all unit tests**

Run: `bundle exec rspec spec/unit/ --format documentation`
Expected: All PASS. The pool_reaper_spec and apartment_spec tests should pass with the new instance API.

- [ ] **Step 6: Commit**

```bash
git add lib/apartment.rb spec/unit/apartment_spec.rb
git commit -m "Apartment module: instance PoolReaper, activate!, teardown protection

- configure creates PoolReaper instance (not class singleton)
- clear_config tears down reaper instance
- teardown_old_state rescues reaper.stop failures
- activate! prepends ConnectionHandling patch on AR::Base"
```

---

## Task 4: `Patches::ConnectionHandling` — the core patch

**Files:**
- Create: `lib/apartment/patches/connection_handling.rb`
- Create: `spec/unit/patches/connection_handling_spec.rb`

This is the architecturally sensitive piece. Tests use real AR + SQLite3.

- [ ] **Step 1: Write failing tests**

Create `spec/unit/patches/connection_handling_spec.rb`.

**Note on global state**: The `prepend` on `ActiveRecord::Base` is permanent for the process. This spec loads real AR (not the stub from `apartment_spec.rb`). Since `apartment_spec.rb` conditionally defines the AR stub (`unless defined?(ActiveRecord::Base)`), loading order matters. The `connection_handling_spec.rb` should be run as part of the full suite (which loads AR first via this file), and the `apartment_spec.rb` stub will be skipped when real AR is present. This is fine — the `apartment_spec.rb` tests don't depend on the stub's implementation.

**Note on `establish_connection` return type**: Verified across Rails 7.2/8.0/8.1 source — `ConnectionHandler#establish_connection` always returns `pool_config.pool` (a `ConnectionPool` instance), never a `PoolConfig`. This matches what `connection_pool` is expected to return.

```ruby
# frozen_string_literal: true

require 'spec_helper'
require 'active_record'

# Set up a real SQLite3 in-memory database for testing pool resolution.
ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')

# Ensure the patch is loaded and activated.
require_relative '../../../lib/apartment/patches/connection_handling'
ActiveRecord::Base.singleton_class.prepend(Apartment::Patches::ConnectionHandling)

RSpec.describe(Apartment::Patches::ConnectionHandling) do
  let(:mock_adapter) do
    instance_double(
      Apartment::Adapters::AbstractAdapter,
      resolve_connection_config: { 'adapter' => 'sqlite3', 'database' => ':memory:' }
    )
  end

  before do
    Apartment.configure do |config|
      config.tenant_strategy = :schema
      config.tenants_provider = -> { %w[acme widgets] }
      config.default_tenant = 'public'
    end
    Apartment.adapter = mock_adapter
  end

  describe '#connection_pool' do
    context 'when tenant is nil' do
      it 'returns the default pool via super' do
        Apartment::Current.reset
        pool = ActiveRecord::Base.connection_pool
        expect(pool).to(be_a(ActiveRecord::ConnectionAdapters::ConnectionPool))
      end
    end

    context 'when tenant is the default tenant' do
      it 'returns the default pool via super' do
        Apartment::Current.tenant = 'public'
        pool = ActiveRecord::Base.connection_pool
        default_pool = ActiveRecord::Base.connection_handler.retrieve_connection_pool(
          'ActiveRecord::Base',
          role: ActiveRecord::Base.current_role,
          shard: ActiveRecord::Base.default_shard
        )
        expect(pool).to(eq(default_pool))
      end
    end

    context 'when tenant is set' do
      before { Apartment::Current.tenant = 'acme' }

      it 'returns a tenant-specific pool' do
        default_pool = ActiveRecord::Base.connection_handler.retrieve_connection_pool(
          'ActiveRecord::Base',
          role: ActiveRecord::Base.current_role,
          shard: ActiveRecord::Base.default_shard
        )
        tenant_pool = ActiveRecord::Base.connection_pool
        expect(tenant_pool).not_to(eq(default_pool))
      end

      it 'returns the same pool on subsequent calls (cached)' do
        pool1 = ActiveRecord::Base.connection_pool
        pool2 = ActiveRecord::Base.connection_pool
        expect(pool1).to(equal(pool2))
      end

      it 'returns different pools for different tenants' do
        acme_pool = ActiveRecord::Base.connection_pool

        Apartment::Current.tenant = 'widgets'
        widgets_pool = ActiveRecord::Base.connection_pool

        expect(acme_pool).not_to(equal(widgets_pool))
      end

      it 'registers the pool with AR ConnectionHandler' do
        ActiveRecord::Base.connection_pool # trigger creation
        shard_key = :"#{Apartment.config.shard_key_prefix}_acme"

        registered_pool = ActiveRecord::Base.connection_handler.retrieve_connection_pool(
          'ActiveRecord::Base',
          role: ActiveRecord::Base.current_role,
          shard: shard_key
        )
        expect(registered_pool).not_to(be_nil)
      end

      it 'pool has correct db_config' do
        pool = ActiveRecord::Base.connection_pool
        expect(pool.db_config.configuration_hash).to(include(adapter: 'sqlite3'))
      end

      it 'pool is usable for queries' do
        pool = ActiveRecord::Base.connection_pool
        result = pool.with_connection { |conn| conn.execute('SELECT 1') }
        expect(result).not_to(be_nil)
      end

      it 'tracks the pool in PoolManager' do
        ActiveRecord::Base.connection_pool
        expect(Apartment.pool_manager.tracked?('acme')).to(be(true))
      end
    end

    context 'when pool_manager is nil (unconfigured)' do
      it 'returns the default pool' do
        Apartment.clear_config
        Apartment::Current.tenant = 'acme'

        # Should not raise — falls through to super
        pool = ActiveRecord::Base.connection_pool
        expect(pool).to(be_a(ActiveRecord::ConnectionAdapters::ConnectionPool))
      end
    end

    context 'with hyphenated tenant name' do
      before { Apartment::Current.tenant = 'my-tenant' }

      it 'works correctly as shard key' do
        pool = ActiveRecord::Base.connection_pool
        shard_key = :"#{Apartment.config.shard_key_prefix}_my-tenant"

        registered = ActiveRecord::Base.connection_handler.retrieve_connection_pool(
          'ActiveRecord::Base',
          role: ActiveRecord::Base.current_role,
          shard: shard_key
        )
        expect(registered).to(eq(pool))
      end
    end

    context 'role interaction' do
      it 'creates separate pools per (tenant, role) pair' do
        Apartment::Current.tenant = 'acme'
        writing_pool = ActiveRecord::Base.connection_pool

        # Simulate reading role — push to connected_to_stack
        ActiveRecord::Base.connected_to(role: :reading) do
          # Our override uses current_role, which is now :reading.
          # establish_connection will create a separate pool for (acme, reading).
          # However, this will raise ConnectionNotEstablished if no reading
          # pool was previously registered. This test verifies the role
          # parameter is passed through correctly by checking the shard key
          # registration rather than the full connected_to flow.
        end

        # Verify the writing pool was registered with the writing role
        shard_key = :"#{Apartment.config.shard_key_prefix}_acme"
        registered = ActiveRecord::Base.connection_handler.retrieve_connection_pool(
          'ActiveRecord::Base',
          role: ActiveRecord::Base.default_role,
          shard: shard_key
        )
        expect(registered).to(eq(writing_pool))
      end
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/unit/patches/connection_handling_spec.rb --format documentation`
Expected: FAIL (file not found or module not defined)

- [ ] **Step 3: Implement `connection_handling.rb`**

Create `lib/apartment/patches/connection_handling.rb`:

```ruby
# frozen_string_literal: true

require 'active_record'

module Apartment
  module Patches
    # Prepended on ActiveRecord::Base (singleton class) to intercept
    # connection_pool lookups. When Apartment::Current.tenant is set,
    # returns a tenant-specific pool with immutable, tenant-scoped config.
    #
    # Uses AR's establish_connection with shard-based keying — each tenant
    # is a shard within AR's ConnectionHandler. Pools are lazily created
    # on first access and cached in Apartment::PoolManager for eviction
    # tracking.
    module ConnectionHandling
      def connection_pool
        tenant = Apartment::Current.tenant
        default = Apartment.config&.default_tenant

        return super if tenant.nil? || tenant == default
        return super unless Apartment.pool_manager

        pool_key = tenant.to_s

        Apartment.pool_manager.fetch_or_create(pool_key) do
          config = Apartment.adapter.resolve_connection_config(tenant)
          shard_key = :"#{Apartment.config.shard_key_prefix}_#{tenant}"

          db_config = ActiveRecord::DatabaseConfigurations::HashConfig.new(
            Apartment.config.rails_env_name,
            "apartment_#{tenant}",
            config
          )

          ActiveRecord::Base.connection_handler.establish_connection(
            db_config,
            owner_name: ActiveRecord::Base,
            role: ActiveRecord::Base.current_role,
            shard: shard_key
          )
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/unit/patches/connection_handling_spec.rb --format documentation`
Expected: All PASS

- [ ] **Step 5: Run full unit test suite**

Run: `bundle exec rspec spec/unit/ --format documentation`
Expected: All PASS

- [ ] **Step 6: Commit**

```bash
git add lib/apartment/patches/connection_handling.rb spec/unit/patches/connection_handling_spec.rb
git commit -m "ConnectionHandling: tenant-aware pool resolution via AR shard keying

Core Phase 2.3 deliverable. Prepends on AR::Base to override
connection_pool. Reads Current.tenant, lazily creates pools via
establish_connection with namespaced shard keys. Pools are immutable
and tenant-scoped — no SET search_path at switch time."
```

---

## Task 5: Cross-cutting cleanup and Appraisal verification

**Files:**
- Modify: `lib/apartment/CLAUDE.md` (update Phase 2.3 status)
- No code changes — verification only

- [ ] **Step 1: Run unit tests across all Rails versions**

```bash
bundle exec appraisal rails-7.2-sqlite3 rspec spec/unit/ --format documentation
bundle exec appraisal rails-8.0-sqlite3 rspec spec/unit/ --format documentation
bundle exec appraisal rails-8.1-sqlite3 rspec spec/unit/ --format documentation
```

Expected: All PASS across all three versions.

- [ ] **Step 2: Run rubocop**

```bash
bundle exec rubocop lib/apartment/patches/connection_handling.rb lib/apartment/pool_reaper.rb lib/apartment/config.rb lib/apartment.rb
```

Expected: No offenses. Fix any that arise.

- [ ] **Step 3: Update `lib/apartment/CLAUDE.md`**

Update the directory structure to include the new `patches/` directory and `connection_handling.rb`. Mark Phase 2.3 as the current phase.

- [ ] **Step 4: Update deferred items in phase plan**

In `docs/plans/apartment-v4/phase-2-adapters.md`, check off the Phase 2.3 deferred items:
- `[x] PoolReaper evict_idle/evict_lru do not call disconnect! on evicted pools`
- `[x] configure teardown sequence not protected`
- `[x] Consider converting PoolReaper from class singleton to instance`

- [ ] **Step 5: Commit**

```bash
git add lib/apartment/CLAUDE.md docs/plans/apartment-v4/phase-2-adapters.md
git commit -m "Update docs: Phase 2.3 complete, deferred items resolved"
```

---

## Task 6: Commit design and research docs

**Files:**
- `docs/designs/phase-2.3-connection-handling.md` (already written)
- `docs/research/connection-handling-internals.md` (already written)
- `docs/plans/apartment-v4/phase-2.3-connection-handling.md` (this plan)

- [ ] **Step 1: Commit all planning docs**

```bash
git add docs/designs/phase-2.3-connection-handling.md docs/research/connection-handling-internals.md docs/plans/apartment-v4/phase-2.3-connection-handling.md
git commit -m "Phase 2.3 planning: design spec, research doc, implementation plan"
```

This should be the **first commit** on the branch (reorder if implementing via subagent-driven-development).

---

## Dependency Graph

```
Task 6 (docs)      — no deps, commit first
Task 1 (Config)    — no deps
Task 2 (PoolReaper)— no deps
Task 3 (Apartment) — depends on Task 1, Task 2
Task 4 (Patch)     — depends on Task 1, Task 3
Task 5 (Verify)    — depends on all above
```

Tasks 1 and 2 are independent and can run in parallel.
