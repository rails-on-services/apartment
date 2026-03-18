# Phase 1: Foundation — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the core infrastructure that everything else depends on — config, tenant context, error hierarchy, pool management, and pool eviction — with no database or Rails dependencies in the unit tests.

**Architecture:** `Apartment::Current` (CurrentAttributes) holds tenant state. `Apartment::Config` validates and stores configuration. `Apartment::PoolManager` wraps a `Concurrent::Map` for thread-safe pool tracking with access timestamps. `Apartment::PoolReaper` uses `Concurrent::TimerTask` for idle eviction and LRU cleanup.

**Tech Stack:** Ruby 3.3+, ActiveSupport 7.2+, concurrent-ruby, Zeitwerk, RSpec

**Spec:** [`docs/designs/apartment-v4.md`](../../designs/apartment-v4.md)

**Reference:** `man/spec-restart` branch has working implementations of Config, Current, and connection adapters. Use as reference, not as copy source — our design spec diverges in several areas (pool eviction, Ruby/Rails minimums, config attributes).

---

## File Map

### New files (create)

| File | Responsibility |
|------|---------------|
| `lib/apartment.rb` | Main module, configure DSL, delegators |
| `lib/apartment/version.rb` | `VERSION = '4.0.0.alpha1'` |
| `lib/apartment/current.rb` | `ActiveSupport::CurrentAttributes` subclass |
| `lib/apartment/config.rb` | Configuration object with validation |
| `lib/apartment/configs/postgresql_config.rb` | PostgreSQL-specific config |
| `lib/apartment/configs/mysql_config.rb` | MySQL-specific config |
| `lib/apartment/errors.rb` | Exception hierarchy |
| `lib/apartment/pool_manager.rb` | `Concurrent::Map` wrapper with timestamps |
| `lib/apartment/pool_reaper.rb` | `Concurrent::TimerTask` eviction |
| `lib/apartment/instrumentation.rb` | AS::Notifications event helpers |
| `ros-apartment.gemspec` | Gem metadata and dependencies |
| `spec/unit/current_spec.rb` | CurrentAttributes behavior |
| `spec/unit/config_spec.rb` | Configuration validation |
| `spec/unit/errors_spec.rb` | Exception hierarchy |
| `spec/unit/pool_manager_spec.rb` | Pool tracking, fetch_or_create, eviction |
| `spec/unit/pool_reaper_spec.rb` | Timer-based eviction |
| `spec/unit/instrumentation_spec.rb` | Notification events |
| `spec/spec_helper.rb` | RSpec config for v4 |

### Modified files

| File | Change |
|------|--------|
| `Gemfile` | Update for v4 dependencies |
| `.ruby-version` | `3.3.x` |

---

## Task 1: Project scaffold and gemspec

**Files:**
- Create: `lib/apartment/version.rb`
- Create: `ros-apartment.gemspec`
- Modify: `Gemfile`

- [ ] **Step 1: Create version file**

```ruby
# lib/apartment/version.rb
# frozen_string_literal: true

module Apartment
  VERSION = '4.0.0.alpha1'
end
```

- [ ] **Step 2: Create gemspec**

```ruby
# ros-apartment.gemspec
# frozen_string_literal: true

require_relative 'lib/apartment/version'

Gem::Specification.new do |s|
  s.name = 'ros-apartment'
  s.version = Apartment::VERSION

  s.authors       = ['Ryan Brunner', 'Brad Robertson', 'Rui Baltazar', 'Mauricio Novelo']
  s.summary       = 'A Ruby gem for managing database multi-tenancy. Apartment Gem drop in replacement'
  s.description   = 'Apartment allows Rack applications to deal with database multi-tenancy through ActiveRecord'
  s.email         = ['ryan@influitive.com', 'brad@influitive.com', 'rui.p.baltazar@gmail.com', 'mauricio@campusesp.com']
  s.files = %w[ros-apartment.gemspec README.md] + `git ls-files -z | grep -E '^lib'`.split("\n")
  s.executables = s.files.grep(%r{^bin/}).map { |f| File.basename(f) }

  s.licenses = ['MIT']
  s.metadata = {
    'homepage_uri' => 'https://github.com/rails-on-services/apartment',
    'bug_tracker_uri' => 'https://github.com/rails-on-services/apartment/issues',
    'changelog_uri' => 'https://github.com/rails-on-services/apartment/releases',
    'source_code_uri' => 'https://github.com/rails-on-services/apartment',
    'rubygems_mfa_required' => 'true',
  }

  s.required_ruby_version = '>= 3.3'

  s.add_dependency('activerecord', '>= 7.2.0', '< 8.2')
  s.add_dependency('activesupport', '>= 7.2.0', '< 8.2')
  s.add_dependency('concurrent-ruby', '>= 1.3.0')
  s.add_dependency('parallel', '>= 1.26.0')
  s.add_dependency('public_suffix', '>= 2.0.5', '< 7')
  s.add_dependency('rack', '>= 3.0.9', '< 4.0')
  s.add_dependency('thor', '>= 1.3.0')
  s.add_dependency('zeitwerk', '>= 2.7.1')
end
```

- [ ] **Step 3: Update Gemfile for v4 development**

Replace the development dependencies section to match v4 needs. Keep the existing appraisal structure but update Rails version constraints.

- [ ] **Step 4: Verify gem loads**

Run: `ruby -e "require_relative 'lib/apartment/version'; puts Apartment::VERSION"`
Expected: `4.0.0.alpha1`

- [ ] **Step 5: Commit**

```bash
git add lib/apartment/version.rb ros-apartment.gemspec Gemfile
git commit -m "Scaffold v4 gemspec and version (4.0.0.alpha1)"
```

---

## Task 2: Error hierarchy

**Files:**
- Create: `lib/apartment/errors.rb`
- Create: `spec/unit/errors_spec.rb`

- [ ] **Step 1: Write the failing test**

```ruby
# spec/unit/errors_spec.rb
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Apartment error hierarchy' do
  it 'defines ApartmentError as base' do
    expect(Apartment::ApartmentError).to be < StandardError
  end

  it 'defines TenantNotFound' do
    expect(Apartment::TenantNotFound).to be < Apartment::ApartmentError
  end

  it 'defines TenantExists' do
    expect(Apartment::TenantExists).to be < Apartment::ApartmentError
  end

  it 'defines AdapterNotFound' do
    expect(Apartment::AdapterNotFound).to be < Apartment::ApartmentError
  end

  it 'defines ConfigurationError' do
    expect(Apartment::ConfigurationError).to be < Apartment::ApartmentError
  end

  it 'defines PoolExhausted' do
    expect(Apartment::PoolExhausted).to be < Apartment::ApartmentError
  end

  it 'defines SchemaLoadError' do
    expect(Apartment::SchemaLoadError).to be < Apartment::ApartmentError
  end

  it 'includes tenant name in TenantNotFound message' do
    error = Apartment::TenantNotFound.new('acme')
    expect(error.message).to include('acme')
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/unit/errors_spec.rb`
Expected: FAIL — `uninitialized constant Apartment::ApartmentError`

- [ ] **Step 3: Write minimal implementation**

```ruby
# lib/apartment/errors.rb
# frozen_string_literal: true

module Apartment
  class ApartmentError < StandardError; end

  class TenantNotFound < ApartmentError
    def initialize(tenant = nil)
      super(tenant ? "Tenant '#{tenant}' not found" : 'Tenant not found')
    end
  end

  class TenantExists < ApartmentError
    def initialize(tenant = nil)
      super(tenant ? "Tenant '#{tenant}' already exists" : 'Tenant already exists')
    end
  end

  class AdapterNotFound < ApartmentError; end
  class ConfigurationError < ApartmentError; end
  class PoolExhausted < ApartmentError; end
  class SchemaLoadError < ApartmentError; end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/unit/errors_spec.rb`
Expected: 8 examples, 0 failures

- [ ] **Step 5: Commit**

```bash
git add lib/apartment/errors.rb spec/unit/errors_spec.rb
git commit -m "Add v4 exception hierarchy"
```

---

## Task 3: Apartment::Current (CurrentAttributes)

**Files:**
- Create: `lib/apartment/current.rb`
- Create: `spec/unit/current_spec.rb`

- [ ] **Step 1: Write the failing test**

```ruby
# spec/unit/current_spec.rb
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Apartment::Current do
  after { described_class.reset }

  describe '.tenant' do
    it 'defaults to nil' do
      expect(described_class.tenant).to be_nil
    end

    it 'can be set and read' do
      described_class.tenant = 'acme'
      expect(described_class.tenant).to eq('acme')
    end
  end

  describe '.previous_tenant' do
    it 'defaults to nil' do
      expect(described_class.previous_tenant).to be_nil
    end

    it 'can be set and read' do
      described_class.previous_tenant = 'old_tenant'
      expect(described_class.previous_tenant).to eq('old_tenant')
    end
  end

  describe '.reset' do
    it 'clears tenant and previous_tenant' do
      described_class.tenant = 'acme'
      described_class.previous_tenant = 'old'
      described_class.reset
      expect(described_class.tenant).to be_nil
      expect(described_class.previous_tenant).to be_nil
    end
  end

  describe 'thread isolation' do
    it 'isolates tenant across threads' do
      described_class.tenant = 'main_thread'

      thread_tenant = nil
      Thread.new {
        thread_tenant = described_class.tenant
      }.join

      expect(described_class.tenant).to eq('main_thread')
      expect(thread_tenant).to be_nil
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/unit/current_spec.rb`
Expected: FAIL — `uninitialized constant Apartment::Current`

- [ ] **Step 3: Write minimal implementation**

```ruby
# lib/apartment/current.rb
# frozen_string_literal: true

require 'active_support/current_attributes'

module Apartment
  class Current < ActiveSupport::CurrentAttributes
    attribute :tenant
    attribute :previous_tenant
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/unit/current_spec.rb`
Expected: 5 examples, 0 failures

- [ ] **Step 5: Commit**

```bash
git add lib/apartment/current.rb spec/unit/current_spec.rb
git commit -m "Add Apartment::Current via ActiveSupport::CurrentAttributes"
```

---

## Task 4: Apartment::Config

**Files:**
- Create: `lib/apartment/config.rb`
- Create: `lib/apartment/configs/postgresql_config.rb`
- Create: `lib/apartment/configs/mysql_config.rb`
- Create: `spec/unit/config_spec.rb`

- [ ] **Step 1: Write the failing test**

```ruby
# spec/unit/config_spec.rb
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Apartment::Config do
  subject(:config) { described_class.new }

  describe 'defaults' do
    it { expect(config.default_tenant).to be_nil }
    it { expect(config.tenant_pool_size).to eq(5) }
    it { expect(config.pool_idle_timeout).to eq(300) }
    it { expect(config.max_total_connections).to be_nil }
    it { expect(config.excluded_models).to eq([]) }
    it { expect(config.persistent_schemas).to eq([]) }
    it { expect(config.seed_after_create).to eq(false) }
    it { expect(config.parallel_migration_threads).to eq(0) }
    it { expect(config.parallel_strategy).to eq(:auto) }
    it { expect(config.environmentify_strategy).to be_nil }
    it { expect(config.elevator).to be_nil }
    it { expect(config.elevator_options).to eq({}) }
    it { expect(config.tenant_not_found_handler).to be_nil }
  end

  describe '#tenant_strategy=' do
    it 'accepts valid strategies' do
      %i[schema database_name shard database_config].each do |strategy|
        config.tenant_strategy = strategy
        expect(config.tenant_strategy).to eq(strategy)
      end
    end

    it 'rejects invalid strategies' do
      expect { config.tenant_strategy = :invalid }.to raise_error(ArgumentError, /invalid/)
    end
  end

  describe '#tenants_provider=' do
    it 'accepts a callable' do
      provider = -> { %w[tenant1 tenant2] }
      config.tenants_provider = provider
      expect(config.tenants_provider).to eq(provider)
    end
  end

  describe '#environmentify_strategy=' do
    it 'accepts nil, :prepend, :append' do
      [nil, :prepend, :append].each do |strategy|
        config.environmentify_strategy = strategy
        expect(config.environmentify_strategy).to eq(strategy)
      end
    end

    it 'accepts a callable' do
      callable = ->(tenant) { "test_#{tenant}" }
      config.environmentify_strategy = callable
      expect(config.environmentify_strategy).to eq(callable)
    end

    it 'rejects invalid symbols' do
      expect { config.environmentify_strategy = :invalid }.to raise_error(ArgumentError)
    end
  end

  describe '#parallel_strategy=' do
    it 'accepts :auto, :threads, :processes' do
      %i[auto threads processes].each do |strategy|
        config.parallel_strategy = strategy
        expect(config.parallel_strategy).to eq(strategy)
      end
    end

    it 'rejects invalid strategies' do
      expect { config.parallel_strategy = :invalid }.to raise_error(ArgumentError)
    end
  end

  describe '#configure_postgres' do
    it 'yields a PostgreSQLConfig' do
      config.configure_postgres do |pg|
        expect(pg).to be_a(Apartment::Configs::PostgreSQLConfig)
        pg.persistent_schemas = %w[ext public]
      end
      expect(config.postgres_config.persistent_schemas).to eq(%w[ext public])
    end
  end

  describe '#configure_mysql' do
    it 'yields a MySQLConfig' do
      config.configure_mysql do |mysql|
        expect(mysql).to be_a(Apartment::Configs::MySQLConfig)
      end
      expect(config.mysql_config).to be_a(Apartment::Configs::MySQLConfig)
    end
  end

  describe '#validate!' do
    before do
      config.tenant_strategy = :schema
      config.tenants_provider = -> { [] }
    end

    it 'passes with valid config' do
      expect { config.validate! }.not_to raise_error
    end

    it 'fails without tenant_strategy' do
      config.instance_variable_set(:@tenant_strategy, nil)
      expect { config.validate! }.to raise_error(Apartment::ConfigurationError, /tenant_strategy/)
    end

    it 'fails without tenants_provider' do
      config.tenants_provider = nil
      expect { config.validate! }.to raise_error(Apartment::ConfigurationError, /tenants_provider/)
    end

    it 'fails if tenants_provider is not callable' do
      config.tenants_provider = %w[tenant1 tenant2]
      expect { config.validate! }.to raise_error(Apartment::ConfigurationError, /callable/)
    end

    it 'fails if both postgres and mysql configured' do
      config.configure_postgres { |pg| pg.persistent_schemas = [] }
      config.configure_mysql { |_mysql| }
      expect { config.validate! }.to raise_error(Apartment::ConfigurationError, /both/)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/unit/config_spec.rb`
Expected: FAIL — `uninitialized constant Apartment::Config`

- [ ] **Step 3: Write implementation**

```ruby
# lib/apartment/config.rb
# frozen_string_literal: true

module Apartment
  class Config
    # Required
    attr_reader :tenant_strategy

    # Required — must be callable
    attr_accessor :tenants_provider

    # Tenant defaults
    attr_accessor :default_tenant, :excluded_models, :persistent_schemas

    # Pool management
    attr_accessor :tenant_pool_size, :pool_idle_timeout, :max_total_connections

    # Lifecycle
    attr_accessor :seed_after_create, :seed_data_file

    # Parallel migrations
    attr_accessor :parallel_migration_threads
    attr_reader :parallel_strategy

    # Environment
    attr_reader :environmentify_strategy

    # Elevator
    attr_accessor :elevator, :elevator_options

    # Error handling
    attr_accessor :tenant_not_found_handler

    # Logging
    attr_accessor :active_record_log

    # Database-specific
    attr_reader :postgres_config, :mysql_config

    TENANT_STRATEGIES = %i[schema database_name shard database_config].freeze
    ENVIRONMENTIFY_STRATEGIES = [nil, :prepend, :append].freeze
    PARALLEL_STRATEGIES = %i[auto threads processes].freeze

    private_constant :TENANT_STRATEGIES, :ENVIRONMENTIFY_STRATEGIES, :PARALLEL_STRATEGIES

    def initialize
      @tenant_strategy = nil
      @tenants_provider = nil
      @default_tenant = nil
      @excluded_models = []
      @persistent_schemas = []
      @tenant_pool_size = 5
      @pool_idle_timeout = 300
      @max_total_connections = nil
      @seed_after_create = false
      @seed_data_file = nil
      @parallel_migration_threads = 0
      @parallel_strategy = :auto
      @environmentify_strategy = nil
      @elevator = nil
      @elevator_options = {}
      @tenant_not_found_handler = nil
      @active_record_log = false
      @postgres_config = nil
      @mysql_config = nil
    end

    def tenant_strategy=(value)
      unless TENANT_STRATEGIES.include?(value)
        raise ArgumentError, "Option #{value} not valid for `tenant_strategy`. Use one of #{TENANT_STRATEGIES.join(', ')}"
      end

      @tenant_strategy = value
    end

    def environmentify_strategy=(value)
      unless value.respond_to?(:call) || ENVIRONMENTIFY_STRATEGIES.include?(value)
        raise ArgumentError, "Option #{value} not valid for `environmentify_strategy`. Use one of #{ENVIRONMENTIFY_STRATEGIES.join(', ')} or a callable"
      end

      @environmentify_strategy = value
    end

    def parallel_strategy=(value)
      unless PARALLEL_STRATEGIES.include?(value)
        raise ArgumentError, "Option #{value} not valid for `parallel_strategy`. Use one of #{PARALLEL_STRATEGIES.join(', ')}"
      end

      @parallel_strategy = value
    end

    def configure_postgres
      @postgres_config = Configs::PostgreSQLConfig.new
      yield(@postgres_config)
    end

    def configure_mysql
      @mysql_config = Configs::MySQLConfig.new
      yield(@mysql_config)
    end

    def validate!
      raise ConfigurationError, 'tenant_strategy is required' if @tenant_strategy.nil?

      unless @tenants_provider.respond_to?(:call)
        raise ConfigurationError, 'tenants_provider must be a callable (e.g., -> { Tenant.pluck(:name) })'
      end

      if @postgres_config && @mysql_config
        raise ConfigurationError, 'Cannot configure both Postgres and MySQL at the same time'
      end
    end
  end
end
```

```ruby
# lib/apartment/configs/postgresql_config.rb
# frozen_string_literal: true

module Apartment
  module Configs
    class PostgreSQLConfig
      attr_accessor :persistent_schemas, :enforce_search_path_reset, :include_schemas_in_dump

      def initialize
        @persistent_schemas = []
        @enforce_search_path_reset = false
        @include_schemas_in_dump = []
      end
    end
  end
end
```

```ruby
# lib/apartment/configs/mysql_config.rb
# frozen_string_literal: true

module Apartment
  module Configs
    class MySQLConfig
      def initialize
        # MySQL-specific options — minimal for now
      end
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/unit/config_spec.rb`
Expected: All examples pass

- [ ] **Step 5: Commit**

```bash
git add lib/apartment/config.rb lib/apartment/configs/ spec/unit/config_spec.rb
git commit -m "Add v4 configuration system with validation"
```

---

## Task 5: Apartment module and configure DSL

**Files:**
- Create: `lib/apartment.rb`
- Create: `spec/spec_helper.rb`

- [ ] **Step 1: Write the failing test**

Add to `spec/unit/config_spec.rb`:

```ruby
RSpec.describe Apartment do
  after { Apartment.clear_config }

  describe '.configure' do
    it 'yields a Config object' do
      Apartment.configure do |config|
        expect(config).to be_a(Apartment::Config)
        config.tenant_strategy = :schema
        config.tenants_provider = -> { [] }
      end
    end

    it 'stores the config' do
      Apartment.configure do |config|
        config.tenant_strategy = :schema
        config.tenants_provider = -> { [] }
        config.default_tenant = 'public'
      end
      expect(Apartment.config.default_tenant).to eq('public')
    end

    it 'validates on configure' do
      expect {
        Apartment.configure do |config|
          # Missing tenant_strategy and tenants_provider
        end
      }.to raise_error(Apartment::ConfigurationError)
    end
  end

  describe '.clear_config' do
    it 'resets config to nil' do
      Apartment.configure do |config|
        config.tenant_strategy = :schema
        config.tenants_provider = -> { [] }
      end
      Apartment.clear_config
      expect(Apartment.config).to be_nil
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/unit/config_spec.rb`
Expected: FAIL — `undefined method 'configure' for Apartment`

- [ ] **Step 3: Write implementation**

```ruby
# lib/apartment.rb
# frozen_string_literal: true

require 'active_support'
require 'active_record'
require 'concurrent'

require 'zeitwerk'
loader = Zeitwerk::Loader.for_gem(warn_on_extra_files: false)
loader.inflector.inflect(
  'mysql_config' => 'MySQLConfig',
  'postgresql_config' => 'PostgreSQLConfig'
)
loader.setup

module Apartment
  class << self
    # @return [Apartment::Config, nil]
    attr_reader :config

    # @return [Apartment::PoolManager, nil]
    attr_reader :pool_manager

    def configure
      @config = Config.new
      yield(@config)
      @config.validate!
      @pool_manager = PoolManager.new
    end

    def clear_config
      @pool_manager&.clear
      @config = nil
      @pool_manager = nil
    end
  end
end
```

- [ ] **Step 4: Create spec_helper.rb**

```ruby
# spec/spec_helper.rb
# frozen_string_literal: true

require 'bundler/setup'
require 'apartment'

RSpec.configure do |config|
  config.order = :random
  config.filter_run_when_matching :focus

  config.after(:each) do
    Apartment::Current.reset
    Apartment.clear_config
  end
end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bundle exec rspec spec/unit/`
Expected: All examples pass

- [ ] **Step 6: Commit**

```bash
git add lib/apartment.rb spec/spec_helper.rb spec/unit/config_spec.rb
git commit -m "Add Apartment module with configure DSL"
```

---

## Task 6: Apartment::PoolManager

**Files:**
- Create: `lib/apartment/pool_manager.rb`
- Create: `spec/unit/pool_manager_spec.rb`

- [ ] **Step 1: Write the failing test**

```ruby
# spec/unit/pool_manager_spec.rb
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Apartment::PoolManager do
  subject(:manager) { described_class.new }

  describe '#fetch_or_create' do
    it 'creates and caches a new entry' do
      result = manager.fetch_or_create('tenant_a') { 'pool_a' }
      expect(result).to eq('pool_a')
    end

    it 'returns cached entry on subsequent calls' do
      call_count = 0
      2.times do
        manager.fetch_or_create('tenant_a') { call_count += 1; "pool_#{call_count}" }
      end
      expect(manager.fetch_or_create('tenant_a') { 'new' }).to eq('pool_1')
    end

    it 'updates last_accessed timestamp' do
      manager.fetch_or_create('tenant_a') { 'pool_a' }
      stats = manager.stats_for('tenant_a')
      expect(stats[:last_accessed]).to be_within(1).of(Time.now)
    end
  end

  describe '#remove' do
    it 'removes a tracked pool' do
      manager.fetch_or_create('tenant_a') { 'pool_a' }
      manager.remove('tenant_a')
      expect(manager.tracked?('tenant_a')).to be false
    end

    it 'returns the removed value' do
      manager.fetch_or_create('tenant_a') { 'pool_a' }
      expect(manager.remove('tenant_a')).to eq('pool_a')
    end

    it 'returns nil for unknown tenants' do
      expect(manager.remove('unknown')).to be_nil
    end
  end

  describe '#idle_tenants' do
    it 'returns tenants idle beyond threshold' do
      manager.fetch_or_create('old') { 'pool_old' }
      # Backdate the timestamp
      manager.instance_variable_get(:@timestamps)['old'] = Time.now - 600
      manager.fetch_or_create('recent') { 'pool_recent' }

      idle = manager.idle_tenants(timeout: 300)
      expect(idle).to include('old')
      expect(idle).not_to include('recent')
    end
  end

  describe '#lru_tenants' do
    it 'returns tenants sorted by least recently accessed' do
      manager.fetch_or_create('a') { 'pool_a' }
      manager.instance_variable_get(:@timestamps)['a'] = Time.now - 300
      manager.fetch_or_create('b') { 'pool_b' }
      manager.instance_variable_get(:@timestamps)['b'] = Time.now - 200
      manager.fetch_or_create('c') { 'pool_c' }

      lru = manager.lru_tenants(count: 2)
      expect(lru).to eq(%w[a b])
    end
  end

  describe '#stats' do
    it 'returns pool count and tenant list' do
      manager.fetch_or_create('a') { 'pool_a' }
      manager.fetch_or_create('b') { 'pool_b' }

      stats = manager.stats
      expect(stats[:total_pools]).to eq(2)
      expect(stats[:tenants]).to contain_exactly('a', 'b')
    end
  end

  describe '#clear' do
    it 'removes all tracked pools' do
      manager.fetch_or_create('a') { 'pool_a' }
      manager.fetch_or_create('b') { 'pool_b' }
      manager.clear
      expect(manager.stats[:total_pools]).to eq(0)
    end
  end

  describe 'thread safety' do
    it 'handles concurrent fetch_or_create without duplicates' do
      results = Concurrent::Array.new
      threads = 10.times.map do
        Thread.new { results << manager.fetch_or_create('shared') { SecureRandom.hex } }
      end
      threads.each(&:join)

      expect(results.uniq.size).to eq(1)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/unit/pool_manager_spec.rb`
Expected: FAIL — `uninitialized constant Apartment::PoolManager`

- [ ] **Step 3: Write implementation**

```ruby
# lib/apartment/pool_manager.rb
# frozen_string_literal: true

require 'concurrent'

module Apartment
  class PoolManager
    def initialize
      @pools = Concurrent::Map.new
      @timestamps = Concurrent::Map.new
    end

    # Fetch an existing pool or create one via the block.
    # Updates last_accessed timestamp on every access.
    def fetch_or_create(tenant_key)
      touch(tenant_key)
      @pools.compute_if_absent(tenant_key) { yield }
    end

    def get(tenant_key)
      touch(tenant_key) if @pools.key?(tenant_key)
      @pools[tenant_key]
    end

    def remove(tenant_key)
      @timestamps.delete(tenant_key)
      @pools.delete(tenant_key)
    end

    def tracked?(tenant_key)
      @pools.key?(tenant_key)
    end

    def stats_for(tenant_key)
      return nil unless tracked?(tenant_key)

      { last_accessed: @timestamps[tenant_key] }
    end

    def idle_tenants(timeout:)
      cutoff = Time.now - timeout
      @timestamps.each_pair.filter_map { |key, ts| key if ts < cutoff }
    end

    def lru_tenants(count:)
      @timestamps.each_pair
                  .sort_by { |_, ts| ts }
                  .first(count)
                  .map(&:first)
    end

    def stats
      {
        total_pools: @pools.size,
        tenants: @pools.keys,
      }
    end

    def clear
      @pools.clear
      @timestamps.clear
    end

    private

    def touch(tenant_key)
      @timestamps[tenant_key] = Time.now
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/unit/pool_manager_spec.rb`
Expected: All examples pass

- [ ] **Step 5: Commit**

```bash
git add lib/apartment/pool_manager.rb spec/unit/pool_manager_spec.rb
git commit -m "Add PoolManager with Concurrent::Map and LRU tracking"
```

---

## Task 7: Apartment::PoolReaper

**Files:**
- Create: `lib/apartment/pool_reaper.rb`
- Create: `spec/unit/pool_reaper_spec.rb`

- [ ] **Step 1: Write the failing test**

```ruby
# spec/unit/pool_reaper_spec.rb
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Apartment::PoolReaper do
  let(:pool_manager) { Apartment::PoolManager.new }
  let(:disconnect_calls) { Concurrent::Array.new }

  # Provide a disconnect callback so we can track evictions without real DB pools
  let(:on_evict) { ->(tenant, _pool) { disconnect_calls << tenant } }

  after { described_class.stop }

  describe '.start / .stop' do
    it 'can start and stop without error' do
      described_class.start(
        pool_manager: pool_manager,
        interval: 0.1,
        idle_timeout: 0.2,
        on_evict: on_evict
      )
      expect(described_class).to be_running
      described_class.stop
      expect(described_class).not_to be_running
    end
  end

  describe 'idle eviction' do
    it 'evicts pools idle beyond timeout' do
      pool_manager.fetch_or_create('stale') { 'pool_stale' }
      # Backdate timestamp
      pool_manager.instance_variable_get(:@timestamps)['stale'] = Time.now - 10

      pool_manager.fetch_or_create('fresh') { 'pool_fresh' }

      described_class.start(
        pool_manager: pool_manager,
        interval: 0.05,
        idle_timeout: 1,
        on_evict: on_evict
      )

      sleep 0.2 # Let the reaper run at least once

      expect(disconnect_calls).to include('stale')
      expect(pool_manager.tracked?('stale')).to be false
      expect(pool_manager.tracked?('fresh')).to be true
    end
  end

  describe 'max_total eviction' do
    it 'evicts LRU pools when over max' do
      3.times do |i|
        pool_manager.fetch_or_create("tenant_#{i}") { "pool_#{i}" }
        pool_manager.instance_variable_get(:@timestamps)["tenant_#{i}"] = Time.now - (300 - i * 100)
      end

      described_class.start(
        pool_manager: pool_manager,
        interval: 0.05,
        idle_timeout: 999, # Don't idle-evict
        max_total: 2,
        on_evict: on_evict
      )

      sleep 0.2

      expect(pool_manager.stats[:total_pools]).to be <= 2
      expect(disconnect_calls).to include('tenant_0') # Oldest
    end
  end

  describe 'protected tenants' do
    it 'never evicts the default tenant' do
      pool_manager.fetch_or_create('public') { 'pool_default' }
      pool_manager.instance_variable_get(:@timestamps)['public'] = Time.now - 9999

      described_class.start(
        pool_manager: pool_manager,
        interval: 0.05,
        idle_timeout: 1,
        default_tenant: 'public',
        on_evict: on_evict
      )

      sleep 0.2

      expect(pool_manager.tracked?('public')).to be true
      expect(disconnect_calls).not_to include('public')
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/unit/pool_reaper_spec.rb`
Expected: FAIL — `uninitialized constant Apartment::PoolReaper`

- [ ] **Step 3: Write implementation**

```ruby
# lib/apartment/pool_reaper.rb
# frozen_string_literal: true

require 'concurrent'

module Apartment
  class PoolReaper
    class << self
      def start(pool_manager:, interval:, idle_timeout:, max_total: nil, default_tenant: nil, on_evict: nil)
        stop if running?

        @pool_manager = pool_manager
        @idle_timeout = idle_timeout
        @max_total = max_total
        @default_tenant = default_tenant
        @on_evict = on_evict

        @timer = Concurrent::TimerTask.new(execution_interval: interval) { reap }
        @timer.execute
      end

      def stop
        @timer&.shutdown
        @timer = nil
      end

      def running?
        @timer&.running? || false
      end

      private

      def reap
        evict_idle
        evict_lru if @max_total
      rescue => e
        # Don't let reaper exceptions kill the timer
        warn "[Apartment::PoolReaper] Error during eviction: #{e.message}"
      end

      def evict_idle
        @pool_manager.idle_tenants(timeout: @idle_timeout).each do |tenant|
          next if tenant == @default_tenant

          pool = @pool_manager.remove(tenant)
          @on_evict&.call(tenant, pool)
        end
      end

      def evict_lru
        excess = @pool_manager.stats[:total_pools] - @max_total
        return if excess <= 0

        candidates = @pool_manager.lru_tenants(count: excess + 1) # +1 in case default is in list
        evicted = 0
        candidates.each do |tenant|
          break if evicted >= excess
          next if tenant == @default_tenant

          pool = @pool_manager.remove(tenant)
          @on_evict&.call(tenant, pool)
          evicted += 1
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/unit/pool_reaper_spec.rb`
Expected: All examples pass

- [ ] **Step 5: Commit**

```bash
git add lib/apartment/pool_reaper.rb spec/unit/pool_reaper_spec.rb
git commit -m "Add PoolReaper with idle eviction and LRU cleanup"
```

---

## Task 8: AS::Notifications instrumentation

**Files:**
- Create: `lib/apartment/instrumentation.rb`
- Create: `spec/unit/instrumentation_spec.rb`

- [ ] **Step 1: Write the failing test**

```ruby
# spec/unit/instrumentation_spec.rb
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Apartment::Instrumentation do
  describe '.instrument' do
    it 'publishes switch.apartment events' do
      events = []
      ActiveSupport::Notifications.subscribe('switch.apartment') { |event| events << event }

      described_class.instrument(:switch, tenant: 'acme', previous_tenant: 'public')

      expect(events.size).to eq(1)
      expect(events.first.payload).to include(tenant: 'acme', previous_tenant: 'public')
    ensure
      ActiveSupport::Notifications.unsubscribe('switch.apartment')
    end

    it 'publishes create.apartment events' do
      events = []
      ActiveSupport::Notifications.subscribe('create.apartment') { |event| events << event }

      described_class.instrument(:create, tenant: 'new_tenant')

      expect(events.size).to eq(1)
      expect(events.first.payload[:tenant]).to eq('new_tenant')
    ensure
      ActiveSupport::Notifications.unsubscribe('create.apartment')
    end

    it 'publishes evict.apartment events' do
      events = []
      ActiveSupport::Notifications.subscribe('evict.apartment') { |event| events << event }

      described_class.instrument(:evict, tenant: 'old', reason: :idle)

      expect(events.first.payload).to include(tenant: 'old', reason: :idle)
    ensure
      ActiveSupport::Notifications.unsubscribe('evict.apartment')
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/unit/instrumentation_spec.rb`
Expected: FAIL — `uninitialized constant Apartment::Instrumentation`

- [ ] **Step 3: Write implementation**

```ruby
# lib/apartment/instrumentation.rb
# frozen_string_literal: true

require 'active_support/notifications'

module Apartment
  module Instrumentation
    EVENTS = %i[switch create drop evict pool_stats].freeze

    def self.instrument(event, payload = {}, &block)
      event_name = "#{event}.apartment"
      if block
        ActiveSupport::Notifications.instrument(event_name, payload, &block)
      else
        ActiveSupport::Notifications.instrument(event_name, payload) { }
      end
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/unit/instrumentation_spec.rb`
Expected: All examples pass

- [ ] **Step 5: Commit**

```bash
git add lib/apartment/instrumentation.rb spec/unit/instrumentation_spec.rb
git commit -m "Add AS::Notifications instrumentation for apartment events"
```

---

## Task 9: Wire PoolReaper eviction to instrumentation

**Files:**
- Modify: `lib/apartment/pool_reaper.rb`

- [ ] **Step 1: Add eviction instrumentation test**

Add to `spec/unit/pool_reaper_spec.rb`:

```ruby
describe 'instrumentation' do
  it 'emits evict.apartment events on eviction' do
    events = Concurrent::Array.new
    ActiveSupport::Notifications.subscribe('evict.apartment') { |event| events << event }

    pool_manager.fetch_or_create('stale') { 'pool_stale' }
    pool_manager.instance_variable_get(:@timestamps)['stale'] = Time.now - 10

    described_class.start(
      pool_manager: pool_manager,
      interval: 0.05,
      idle_timeout: 1,
      on_evict: on_evict
    )

    sleep 0.2

    expect(events.any? { |e| e.payload[:tenant] == 'stale' }).to be true
  ensure
    ActiveSupport::Notifications.unsubscribe('evict.apartment')
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/unit/pool_reaper_spec.rb`
Expected: FAIL on the new instrumentation test

- [ ] **Step 3: Update PoolReaper to emit events**

In `lib/apartment/pool_reaper.rb`, update the `evict_idle` and `evict_lru` methods to call `Instrumentation.instrument`:

```ruby
def evict_idle
  @pool_manager.idle_tenants(timeout: @idle_timeout).each do |tenant|
    next if tenant == @default_tenant

    pool = @pool_manager.remove(tenant)
    Instrumentation.instrument(:evict, tenant: tenant, reason: :idle)
    @on_evict&.call(tenant, pool)
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
    Instrumentation.instrument(:evict, tenant: tenant, reason: :lru)
    @on_evict&.call(tenant, pool)
    evicted += 1
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/unit/pool_reaper_spec.rb`
Expected: All examples pass

- [ ] **Step 5: Commit**

```bash
git add lib/apartment/pool_reaper.rb spec/unit/pool_reaper_spec.rb
git commit -m "Wire PoolReaper eviction to AS::Notifications instrumentation"
```

---

## Task 10: Full Phase 1 integration test

**Files:**
- Create: `spec/unit/phase1_integration_spec.rb`

- [ ] **Step 1: Write the integration test**

```ruby
# spec/unit/phase1_integration_spec.rb
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Phase 1 integration' do
  after { Apartment.clear_config }

  it 'configure -> pool_manager -> current -> reaper work together' do
    Apartment.configure do |config|
      config.tenant_strategy = :schema
      config.tenants_provider = -> { %w[acme globex] }
      config.default_tenant = 'public'
      config.tenant_pool_size = 5
      config.pool_idle_timeout = 1
    end

    expect(Apartment.config.tenant_strategy).to eq(:schema)
    expect(Apartment.pool_manager).to be_a(Apartment::PoolManager)

    # Simulate tenant switching via Current
    Apartment::Current.tenant = 'acme'
    expect(Apartment::Current.tenant).to eq('acme')

    # Pool manager tracks tenant pools
    pool = Apartment.pool_manager.fetch_or_create('acme') { 'fake_pool' }
    expect(pool).to eq('fake_pool')

    # Stats work
    stats = Apartment.pool_manager.stats
    expect(stats[:total_pools]).to eq(1)
    expect(stats[:tenants]).to eq(['acme'])

    # Current resets cleanly
    Apartment::Current.reset
    expect(Apartment::Current.tenant).to be_nil
  end

  it 'raises correct errors for invalid config' do
    expect {
      Apartment.configure do |config|
        config.tenant_strategy = :schema
        # Missing tenants_provider
      end
    }.to raise_error(Apartment::ConfigurationError)
  end

  it 'raises TenantNotFound with tenant name' do
    error = Apartment::TenantNotFound.new('missing')
    expect(error.message).to eq("Tenant 'missing' not found")
    expect(error).to be_a(Apartment::ApartmentError)
  end
end
```

- [ ] **Step 2: Run all Phase 1 specs**

Run: `bundle exec rspec spec/unit/`
Expected: All examples pass

- [ ] **Step 3: Commit**

```bash
git add spec/unit/phase1_integration_spec.rb
git commit -m "Add Phase 1 integration test"
```

---

## Completion Checklist

After all tasks are done:

- [ ] All specs pass: `bundle exec rspec spec/unit/`
- [ ] No Zeitwerk eager load errors: `bundle exec ruby -e "require 'apartment'; Zeitwerk::Loader.eager_load_all"`
- [ ] Gem builds: `gem build ros-apartment.gemspec`
- [ ] All files committed, branch ready for PR
