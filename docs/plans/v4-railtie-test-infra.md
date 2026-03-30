# v4 Railtie + Test Infrastructure Overhaul — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a minimal v4 Railtie so Apartment works in a real Rails app, add tenant name validation, and overhaul the test infrastructure with ConnectionHandler swap, scenario configs, dummy app upgrade, and coverage tooling.

**Architecture:** Six task groups executed sequentially. Tasks 1-3 are implementation (validator, config, railtie). Tasks 4-6 are test infrastructure (ConnectionHandler swap, scenario configs, dummy app). Task 7 is coverage tooling. Each group produces a commit.

**Tech Stack:** Ruby 3.3+, Rails 7.2+, RSpec, ActiveRecord, Rack::Test, SimpleCov, TestProf

**Spec:** `docs/designs/v4-railtie-test-infra.md`

---

## File Map

### New files (create)

| File | Responsibility |
|------|---------------|
| `lib/apartment/tenant_name_validator.rb` | Pure in-memory tenant name format validation per engine |
| `lib/apartment/tasks/v4.rake` | v4 rake tasks (apartment:create, :drop, :migrate, :seed, :rollback) |
| `spec/unit/tenant_name_validator_spec.rb` | Validator unit tests |
| `spec/unit/railtie_spec.rb` | Railtie hook unit tests (mocked Rails) |
| `spec/integration/v4/request_lifecycle_spec.rb` | Dummy app end-to-end request tests |
| `spec/integration/v4/scenarios/postgresql_schema.yml` | PG schema-per-tenant scenario config |
| `spec/integration/v4/scenarios/postgresql_database.yml` | PG database-per-tenant scenario config |
| `spec/integration/v4/scenarios/mysql_database.yml` | MySQL database-per-tenant scenario config |
| `spec/integration/v4/scenarios/sqlite_file.yml` | SQLite file-per-tenant scenario config |
| `spec/dummy/app/controllers/tenants_controller.rb` | Test controller for request lifecycle |

### Modified files

| File | Change |
|------|--------|
| `lib/apartment.rb` | Remove `railtie` from Zeitwerk ignore list |
| `lib/apartment/railtie.rb` | Replace v3 with v4 implementation |
| `lib/apartment/config.rb` | Add `schema_load_strategy`, `schema_file` options + validation |
| `lib/apartment/adapters/abstract_adapter.rb` | Add `validated_connection_config`, `import_schema`, call validator in `create` |
| `lib/apartment/patches/connection_handling.rb` | Call `validated_connection_config` instead of `resolve_connection_config` |
| `spec/integration/v4/support.rb` | ConnectionHandler swap, scenario loading helpers |
| `spec/dummy/config/initializers/apartment.rb` | v4 configure block |
| `spec/dummy/config/application.rb` | Remove v3 requires, let Railtie handle middleware |
| `spec/dummy/config/database.yml` | Update to modern format |
| `spec/dummy/config/routes.rb` | Add `/tenant_info` route |
| `spec/dummy/config/environments/test.rb` | Modernize for Rails 7.2+ |
| `Gemfile` | Add simplecov, test-prof, rack-test |

---

## Task 1: Tenant Name Validator

**Files:**
- Create: `lib/apartment/tenant_name_validator.rb`
- Create: `spec/unit/tenant_name_validator_spec.rb`

This is a pure module with no dependencies on Apartment internals. Build and test it first in isolation.

### Implementation

`lib/apartment/tenant_name_validator.rb`:

```ruby
# frozen_string_literal: true

module Apartment
  module TenantNameValidator
    module_function

    # Validate a tenant name against common and engine-specific rules.
    # Raises ConfigurationError on invalid names. Pure in-memory check — no IO.
    def validate!(name, strategy:, adapter_name: nil)
      validate_common!(name)
      case strategy
      when :schema
        validate_postgresql_identifier!(name)
      when :database_name
        validate_for_adapter!(name, adapter_name)
      end
      # :shard and :database_config use common validation only (not yet implemented).
    end

    # --- Common rules (all engines) ---

    def validate_common!(name)
      raise(ConfigurationError, 'Tenant name must be a String') unless name.is_a?(String)
      raise(ConfigurationError, 'Tenant name cannot be empty') if name.empty?
      raise(ConfigurationError, "Tenant name contains NUL byte: #{name.inspect}") if name.include?("\x00")
      raise(ConfigurationError, "Tenant name contains whitespace: #{name.inspect}") if name.match?(/\s/)
      raise(ConfigurationError, "Tenant name too long (#{name.length} chars, max 255): #{name.inspect}") if name.length > 255
    end

    # --- PostgreSQL identifiers (schema names, database names) ---
    # Hyphens are allowed — our adapters quote via quote_table_name.
    # Cannot start with pg_ (reserved prefix).

    def validate_postgresql_identifier!(name)
      if name.length > 63
        raise(ConfigurationError, "PostgreSQL identifier too long (#{name.length} chars, max 63): #{name.inspect}")
      end
      unless name.match?(/\A[a-zA-Z_][a-zA-Z0-9_-]*\z/)
        raise(ConfigurationError,
              "Invalid PostgreSQL identifier: #{name.inspect}. " \
              'Must start with letter/underscore, contain only letters, digits, underscores, hyphens')
      end
      return unless name.start_with?('pg_')

      raise(ConfigurationError, "Tenant name cannot start with 'pg_' (reserved prefix): #{name.inspect}")
    end

    # --- MySQL database names ---
    # Max 64 chars, allowed: [a-zA-Z0-9_$-], no leading digit, no trailing dot.

    def validate_mysql_database_name!(name)
      if name.length > 64
        raise(ConfigurationError, "MySQL database name too long (#{name.length} chars, max 64): #{name.inspect}")
      end
      if name.match?(/\A\d/)
        raise(ConfigurationError, "MySQL database name cannot start with a digit: #{name.inspect}")
      end
      if name.end_with?('.')
        raise(ConfigurationError, "MySQL database name cannot end with a period: #{name.inspect}")
      end
      return unless name.match?(%r{[^a-zA-Z0-9_$-]})

      raise(ConfigurationError,
              "Invalid MySQL database name: #{name.inspect}. " \
              'Allowed characters: letters, digits, underscore, dollar sign, hyphen')
    end

    # --- SQLite file paths ---
    # No path traversal, filesystem-safe characters.

    def validate_sqlite_path!(name)
      if name.include?('..')
        raise(ConfigurationError, "SQLite tenant name contains path traversal: #{name.inspect}")
      end
      return unless name.match?(%r{[/\\]})

      raise(ConfigurationError, "SQLite tenant name contains path separators: #{name.inspect}")
    end

    # --- Dispatcher for :database_name strategy ---

    def validate_for_adapter!(name, adapter_name)
      case adapter_name
      when /mysql/i, /trilogy/i then validate_mysql_database_name!(name)
      when /postgresql/i, /postgis/i then validate_postgresql_identifier!(name)
      when /sqlite/i then validate_sqlite_path!(name)
      end
    end
  end
end
```

### Tests

`spec/unit/tenant_name_validator_spec.rb`:

```ruby
# frozen_string_literal: true

require 'spec_helper'
require_relative '../../lib/apartment/tenant_name_validator'

RSpec.describe(Apartment::TenantNameValidator) do
  describe '.validate! common rules' do
    it 'rejects nil' do
      expect { described_class.validate!(nil, strategy: :schema) }
        .to(raise_error(Apartment::ConfigurationError, /must be a String/))
    end

    it 'rejects empty string' do
      expect { described_class.validate!('', strategy: :schema) }
        .to(raise_error(Apartment::ConfigurationError, /cannot be empty/))
    end

    it 'rejects NUL bytes' do
      expect { described_class.validate!("foo\x00bar", strategy: :schema) }
        .to(raise_error(Apartment::ConfigurationError, /NUL byte/))
    end

    it 'rejects whitespace' do
      expect { described_class.validate!("foo bar", strategy: :schema) }
        .to(raise_error(Apartment::ConfigurationError, /whitespace/))
    end

    it 'rejects names longer than 255 characters' do
      expect { described_class.validate!('a' * 256, strategy: :database_name, adapter_name: 'sqlite3') }
        .to(raise_error(Apartment::ConfigurationError, /too long.*256.*max 255/))
    end

    it 'accepts valid names' do
      expect { described_class.validate!('acme', strategy: :schema) }.not_to(raise_error)
    end
  end

  describe 'PostgreSQL identifier rules' do
    it 'rejects names longer than 63 characters' do
      expect { described_class.validate!('a' * 64, strategy: :schema) }
        .to(raise_error(Apartment::ConfigurationError, /too long.*64.*max 63/))
    end

    it 'rejects names starting with pg_' do
      expect { described_class.validate!('pg_custom', strategy: :schema) }
        .to(raise_error(Apartment::ConfigurationError, /reserved prefix/))
    end

    it 'rejects names starting with a digit' do
      expect { described_class.validate!('123abc', strategy: :schema) }
        .to(raise_error(Apartment::ConfigurationError, /Invalid PostgreSQL identifier/))
    end

    it 'rejects names with special characters' do
      expect { described_class.validate!('foo@bar', strategy: :schema) }
        .to(raise_error(Apartment::ConfigurationError, /Invalid PostgreSQL identifier/))
    end

    it 'allows hyphens (quoted by adapters)' do
      expect { described_class.validate!('my-tenant', strategy: :schema) }.not_to(raise_error)
    end

    it 'allows underscores' do
      expect { described_class.validate!('my_tenant', strategy: :schema) }.not_to(raise_error)
    end

    it 'allows names starting with underscore' do
      expect { described_class.validate!('_private', strategy: :schema) }.not_to(raise_error)
    end
  end

  describe 'MySQL database name rules' do
    let(:opts) { { strategy: :database_name, adapter_name: 'mysql2' } }

    it 'rejects names longer than 64 characters' do
      expect { described_class.validate!('a' * 65, **opts) }
        .to(raise_error(Apartment::ConfigurationError, /too long.*65.*max 64/))
    end

    it 'rejects names starting with a digit' do
      expect { described_class.validate!('123abc', **opts) }
        .to(raise_error(Apartment::ConfigurationError, /cannot start with a digit/))
    end

    it 'rejects names ending with a period' do
      expect { described_class.validate!('foo.', **opts) }
        .to(raise_error(Apartment::ConfigurationError, /cannot end with a period/))
    end

    it 'rejects names with invalid characters' do
      expect { described_class.validate!('foo@bar', **opts) }
        .to(raise_error(Apartment::ConfigurationError, /Invalid MySQL/))
    end

    it 'allows hyphens and dollar signs' do
      expect { described_class.validate!('my-tenant$1', **opts) }.not_to(raise_error)
    end

    it 'applies to trilogy adapter' do
      expect { described_class.validate!('foo@bar', strategy: :database_name, adapter_name: 'trilogy') }
        .to(raise_error(Apartment::ConfigurationError, /Invalid MySQL/))
    end
  end

  describe 'SQLite path rules' do
    let(:opts) { { strategy: :database_name, adapter_name: 'sqlite3' } }

    it 'rejects path traversal' do
      expect { described_class.validate!('../escape', **opts) }
        .to(raise_error(Apartment::ConfigurationError, /path traversal/))
    end

    it 'rejects path separators' do
      expect { described_class.validate!('dir/name', **opts) }
        .to(raise_error(Apartment::ConfigurationError, /path separators/))
    end

    it 'allows normal names' do
      expect { described_class.validate!('my_tenant', **opts) }.not_to(raise_error)
    end
  end

  describe 'unknown strategy' do
    it 'applies only common validation for :shard strategy' do
      expect { described_class.validate!('acme', strategy: :shard) }.not_to(raise_error)
    end
  end
end
```

- [ ] Write `lib/apartment/tenant_name_validator.rb`
- [ ] Write `spec/unit/tenant_name_validator_spec.rb`
- [ ] Run: `bundle exec rspec spec/unit/tenant_name_validator_spec.rb`
- [ ] Run: `bundle exec rubocop lib/apartment/tenant_name_validator.rb spec/unit/tenant_name_validator_spec.rb`
- [ ] Commit: `git commit -m "Add TenantNameValidator with engine-specific format rules"`

---

## Task 2: Wire Validator into AbstractAdapter + ConnectionHandling

**Files:**
- Modify: `lib/apartment/adapters/abstract_adapter.rb`
- Modify: `lib/apartment/patches/connection_handling.rb`
- Modify: `spec/unit/adapters/abstract_adapter_spec.rb`
- Modify: `spec/unit/patches/connection_handling_spec.rb`

### Implementation

Add `validated_connection_config` template method to `AbstractAdapter`:

```ruby
# In AbstractAdapter, add above resolve_connection_config:

# Template method: validates tenant name then delegates to resolve_connection_config.
# Called by ConnectionHandling — subclasses should NOT override this.
def validated_connection_config(tenant)
  TenantNameValidator.validate!(
    tenant,
    strategy: Apartment.config.tenant_strategy,
    adapter_name: base_config['adapter']
  )
  resolve_connection_config(tenant)
end
```

Add validation to `create`:

```ruby
# In AbstractAdapter#create, add before create_tenant:
def create(tenant)
  TenantNameValidator.validate!(
    tenant,
    strategy: Apartment.config.tenant_strategy,
    adapter_name: base_config['adapter']
  )
  run_callbacks(:create) do
    # ... existing code
  end
end
```

Add `require_relative 'tenant_name_validator'` to `abstract_adapter.rb`.

Update `ConnectionHandling#connection_pool` to call `validated_connection_config`:

```ruby
# In connection_handling.rb, change:
#   config = Apartment.adapter.resolve_connection_config(tenant)
# To:
#   config = Apartment.adapter.validated_connection_config(tenant)
```

### Tests

Add to `spec/unit/adapters/abstract_adapter_spec.rb`:

```ruby
describe '#validated_connection_config' do
  it 'returns the resolved config for valid tenant names' do
    result = adapter.validated_connection_config('acme')
    expect(result).to(eq(adapter: 'postgresql', database: 'acme'))
  end

  it 'raises ConfigurationError for invalid tenant names' do
    expect { adapter.validated_connection_config("bad\x00name") }
      .to(raise_error(Apartment::ConfigurationError, /NUL byte/))
  end
end

# Update existing create test:
describe '#create' do
  it 'raises ConfigurationError for invalid tenant names' do
    expect { adapter.create("bad\x00name") }
      .to(raise_error(Apartment::ConfigurationError, /NUL byte/))
  end
end
```

- [ ] Add `validated_connection_config` to `AbstractAdapter`
- [ ] Add validation call to `AbstractAdapter#create`
- [ ] Update `ConnectionHandling` to call `validated_connection_config`
- [ ] Add unit tests for the new methods
- [ ] Run: `bundle exec rspec spec/unit/adapters/abstract_adapter_spec.rb spec/unit/patches/connection_handling_spec.rb`
- [ ] Run: `bundle exec rspec spec/unit/` (full unit suite)
- [ ] Run: `bundle exec rubocop` on changed files
- [ ] Commit: `git commit -m "Wire TenantNameValidator into adapter create and pool resolution"`

---

## Task 3: Config additions (schema_load_strategy, schema_file)

**Files:**
- Modify: `lib/apartment/config.rb`
- Modify: `spec/unit/config_spec.rb`

### Implementation

Add to `Config#initialize`:

```ruby
@schema_load_strategy = :schema_rb  # default: load db/schema.rb
@schema_file = nil                   # nil = auto-detect from Rails or default
```

Add attr_accessor:

```ruby
attr_accessor :tenants_provider, :default_tenant, :excluded_models,
              # ... existing ...
              :schema_load_strategy, :schema_file
```

Add validation in `validate!`:

```ruby
unless [nil, :schema_rb, :sql].include?(@schema_load_strategy)
  raise(ConfigurationError, "Invalid schema_load_strategy: #{@schema_load_strategy.inspect}. " \
                            'Must be nil, :schema_rb, or :sql')
end
```

### Tests

```ruby
describe 'schema_load_strategy' do
  it 'defaults to :schema_rb' do
    config = described_class.new
    expect(config.schema_load_strategy).to eq(:schema_rb)
  end

  it 'accepts nil, :schema_rb, and :sql' do
    %i[schema_rb sql].each do |strategy|
      config = described_class.new
      config.schema_load_strategy = strategy
      expect(config.schema_load_strategy).to eq(strategy)
    end
  end

  it 'rejects invalid values during validation' do
    # Must go through full configure flow since validate! checks it
    expect {
      Apartment.configure do |c|
        c.tenant_strategy = :schema
        c.tenants_provider = -> { [] }
        c.schema_load_strategy = :invalid
      end
    }.to raise_error(Apartment::ConfigurationError, /Invalid schema_load_strategy/)
  end
end
```

- [ ] Add `schema_load_strategy` and `schema_file` to `Config`
- [ ] Add validation in `Config#validate!`
- [ ] Add unit tests
- [ ] Run: `bundle exec rspec spec/unit/config_spec.rb`
- [ ] Commit: `git commit -m "Add schema_load_strategy and schema_file config options"`

---

## Task 4: Schema loading in AbstractAdapter#create + import_schema

**Files:**
- Modify: `lib/apartment/adapters/abstract_adapter.rb`
- Modify: `spec/unit/adapters/abstract_adapter_spec.rb`

### Implementation

Add `import_schema` private method and update `create`:

```ruby
def create(tenant)
  TenantNameValidator.validate!(
    tenant,
    strategy: Apartment.config.tenant_strategy,
    adapter_name: base_config['adapter']
  )
  run_callbacks(:create) do
    create_tenant(tenant)
    import_schema(tenant) if Apartment.config.schema_load_strategy
    seed(tenant) if Apartment.config.seed_after_create
    Instrumentation.instrument(:create, tenant: tenant)
  end
end

private

def import_schema(tenant)
  Apartment::Tenant.switch(tenant) do
    schema_file = resolve_schema_file
    case Apartment.config.schema_load_strategy
    when :schema_rb
      load(schema_file)
    when :sql
      ActiveRecord::Tasks::DatabaseTasks.load_schema(
        ActiveRecord::Base.connection_db_config, :sql, schema_file
      )
    end
  end
rescue StandardError => e
  raise(Apartment::SchemaLoadError,
        "Failed to load schema for tenant '#{tenant}': #{e.class}: #{e.message}")
end

def resolve_schema_file
  custom = Apartment.config.schema_file
  return custom if custom

  if defined?(Rails)
    Rails.root.join('db', 'schema.rb').to_s
  else
    'db/schema.rb'
  end
end
```

### Tests

```ruby
describe '#create with schema loading' do
  before do
    reconfigure(schema_load_strategy: :schema_rb)
    allow(Apartment::Instrumentation).to(receive(:instrument))
  end

  it 'calls import_schema when schema_load_strategy is set' do
    expect(adapter).to(receive(:import_schema).with('acme'))
    adapter.create('acme')
  end

  it 'does not call import_schema when strategy is nil' do
    reconfigure(schema_load_strategy: nil)
    expect(adapter).not_to(receive(:import_schema))
    adapter.create('acme')
  end

  it 'calls seed after schema import when seed_after_create is true' do
    reconfigure(schema_load_strategy: :schema_rb, seed_after_create: true, seed_data_file: '/tmp/seeds.rb')
    call_order = []
    allow(adapter).to(receive(:import_schema) { call_order << :schema })
    allow(File).to(receive(:exist?).and_return(true))
    allow(adapter).to(receive(:load) { call_order << :seed })
    adapter.create('acme')
    expect(call_order).to(eq([:schema, :seed]))
  end

  it 'raises SchemaLoadError when schema loading fails' do
    allow(adapter).to(receive(:import_schema).and_raise(
      Apartment::SchemaLoadError, "Failed to load schema for tenant 'acme': RuntimeError: boom"
    ))
    expect { adapter.create('acme') }.to(raise_error(Apartment::SchemaLoadError, /boom/))
  end
end

describe '#resolve_schema_file (private)' do
  it 'returns custom schema_file when configured' do
    reconfigure(schema_file: '/custom/schema.rb')
    expect(adapter.send(:resolve_schema_file)).to(eq('/custom/schema.rb'))
  end

  it 'returns Rails.root/db/schema.rb when Rails is defined' do
    # Rails is stubbed at the top of this spec file
    expect(adapter.send(:resolve_schema_file)).to(include('db/schema.rb'))
  end

  it 'returns db/schema.rb as fallback' do
    allow(adapter).to(receive(:defined?).and_return(false))
    # In practice, without Rails defined, falls back to 'db/schema.rb'
    result = adapter.send(:resolve_schema_file)
    expect(result).to(end_with('schema.rb'))
  end
end

describe '#import_schema (private)' do
  it 'calls load with the resolved schema file for :schema_rb strategy' do
    reconfigure(schema_load_strategy: :schema_rb, schema_file: '/tmp/test_schema.rb')
    # import_schema switches tenant and calls load(path)
    expect(adapter).to(receive(:load).with('/tmp/test_schema.rb'))
    adapter.send(:import_schema, 'acme')
  end

  it 'wraps load errors in SchemaLoadError' do
    reconfigure(schema_load_strategy: :schema_rb, schema_file: '/tmp/bad_schema.rb')
    allow(adapter).to(receive(:load).and_raise(RuntimeError, 'syntax error'))
    expect { adapter.send(:import_schema, 'acme') }
      .to(raise_error(Apartment::SchemaLoadError, /syntax error/))
  end
end
```

- [ ] Add `import_schema` and `resolve_schema_file` to `AbstractAdapter`
- [ ] Update `create` to call `import_schema` and `seed`
- [ ] Add unit tests
- [ ] Run: `bundle exec rspec spec/unit/adapters/abstract_adapter_spec.rb`
- [ ] Run: `bundle exec rspec spec/unit/` (full suite — ensure no regressions)
- [ ] Commit: `git commit -m "Add schema loading during tenant creation via import_schema"`

---

## Task 5: v4 Railtie

**Files:**
- Replace: `lib/apartment/railtie.rb`
- Modify: `lib/apartment.rb` (remove from Zeitwerk ignore)
- Create: `lib/apartment/tasks/v4.rake`
- Create: `spec/unit/railtie_spec.rb`

### Implementation

`lib/apartment/railtie.rb`:

```ruby
# frozen_string_literal: true

require 'rails'

module Apartment
  class Railtie < Rails::Railtie
    # After all initializers have run: wire up Apartment if configured.
    config.after_initialize do
      next unless Apartment.config

      # Warn if isolation_level is :thread — v4 needs :fiber for CurrentAttributes safety.
      if defined?(ActiveSupport::IsolatedExecutionState) &&
         ActiveSupport::IsolatedExecutionState.isolation_level == :thread
        warn '[Apartment] WARNING: ActiveSupport isolation_level is :thread. ' \
             'Apartment v4 requires :fiber for correct CurrentAttributes propagation. ' \
             'Set config.active_support.isolation_level = :fiber in your application config.'
      end

      begin
        Apartment.activate!
        Apartment::Tenant.init
      rescue ActiveRecord::NoDatabaseError
        # Swallow: database may not exist yet (db:create compatibility).
        warn '[Apartment] Database not found during init — skipping. Run db:create first.'
      end
    end

    # Insert elevator middleware if configured.
    initializer 'apartment.middleware' do |app|
      next unless Apartment.config&.elevator

      elevator_class = resolve_elevator_class(Apartment.config.elevator)
      options = Apartment.config.elevator_options || {}
      app.middleware.use(elevator_class, *options.values)
    end

    rake_tasks do
      load File.expand_path('tasks/v4.rake', __dir__)
    end

    private

    def resolve_elevator_class(elevator)
      class_name = "Apartment::Elevators::#{elevator.to_s.camelize}"
      # Require the elevator file — elevators are not autoloaded (Zeitwerk-ignored directory).
      require "apartment/elevators/#{elevator}"
      class_name.constantize
    rescue NameError, LoadError => e
      available = Dir[File.join(__dir__, 'elevators', '*.rb')]
                    .map { |f| File.basename(f, '.rb') }
                    .reject { |n| n == 'generic' }
      raise(Apartment::ConfigurationError,
            "Unknown elevator '#{elevator}': #{e.message}. " \
            "Available elevators: #{available.join(', ')}")
    end
  end
end
```

Remove `railtie` from Zeitwerk ignore list in `lib/apartment.rb`:

```ruby
# Change this:
%w[
  railtie
  deprecation
  ...
].each { |f| loader.ignore("#{__dir__}/apartment/#{f}.rb") }

# To this (remove 'railtie' from the list):
%w[
  deprecation
  ...
].each { |f| loader.ignore("#{__dir__}/apartment/#{f}.rb") }
```

`lib/apartment/tasks/v4.rake`:

```ruby
# frozen_string_literal: true

namespace :apartment do
  desc 'Create all tenant schemas/databases from tenants_provider'
  task create: :environment do
    tenants = Apartment.config.tenants_provider.call
    tenants.each do |tenant|
      puts "Creating tenant: #{tenant}"
      Apartment::Tenant.create(tenant)
    rescue Apartment::TenantExists
      puts "  already exists, skipping"
    rescue StandardError => e
      warn "  FAILED: #{e.message}"
    end
  end

  desc 'Drop a tenant schema/database'
  task :drop, [:tenant] => :environment do |_t, args|
    abort 'Usage: rake apartment:drop[tenant_name]' unless args[:tenant]
    Apartment::Tenant.drop(args[:tenant])
    puts "Dropped tenant: #{args[:tenant]}"
  end

  desc 'Run migrations for all tenants'
  task migrate: :environment do
    tenants = Apartment.config.tenants_provider.call
    tenants.each do |tenant|
      puts "Migrating tenant: #{tenant}"
      Apartment::Tenant.migrate(tenant)
    rescue StandardError => e
      warn "  FAILED: #{e.message}"
    end
  end

  desc 'Seed all tenants'
  task seed: :environment do
    tenants = Apartment.config.tenants_provider.call
    tenants.each do |tenant|
      puts "Seeding tenant: #{tenant}"
      Apartment::Tenant.seed(tenant)
    rescue StandardError => e
      warn "  FAILED: #{e.message}"
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
end
```

### Tests

`spec/unit/railtie_spec.rb` — test `resolve_elevator_class` as a module-level helper. The Railtie's boot-time behavior (after_initialize, middleware insertion) is tested via the dummy app (Task 8). Unit tests only verify the elevator resolution helper.

Note: `Rails::Railtie` doesn't expose `.instance` — we test `resolve_elevator_class` by extracting it into a testable method or calling it on a fresh Railtie instance via `.send(:new)`. The Railtie spec must guard with a `LoadError` rescue since it requires Rails.

```ruby
# frozen_string_literal: true

require 'spec_helper'

# Railtie requires Rails — skip gracefully when running outside appraisal.
RAILTIE_AVAILABLE = begin
  require 'apartment/railtie'
  true
rescue LoadError
  false
end

RSpec.describe('Apartment::Railtie',
               skip: (RAILTIE_AVAILABLE ? false : 'requires Rails')) do
  # Rails::Railtie doesn't expose .instance — instantiate directly for testing.
  let(:railtie) { described_class.send(:new) }

  describe 'elevator resolution' do
    it 'resolves :subdomain to Apartment::Elevators::Subdomain' do
      klass = railtie.send(:resolve_elevator_class, :subdomain)
      expect(klass).to(eq(Apartment::Elevators::Subdomain))
    end

    it 'raises ConfigurationError for unknown elevator' do
      expect { railtie.send(:resolve_elevator_class, :nonexistent) }
        .to(raise_error(Apartment::ConfigurationError, /Unknown elevator/))
    end
  end
end
```

- [ ] Replace `lib/apartment/railtie.rb` with v4 implementation
- [ ] Remove `railtie` from Zeitwerk ignore list in `lib/apartment.rb`
- [ ] Create `lib/apartment/tasks/v4.rake`
- [ ] Create `spec/unit/railtie_spec.rb`
- [ ] Run: `bundle exec rspec spec/unit/`
- [ ] Run: `bundle exec rubocop lib/apartment/railtie.rb lib/apartment/tasks/v4.rake`
- [ ] Commit: `git commit -m "Add v4 Railtie with after_initialize, middleware insertion, and rake tasks"`

---

## Task 6: ConnectionHandler Swap in Integration Tests

**Files:**
- Modify: `spec/integration/v4/support.rb`

### Implementation

Add an `around` hook to `support.rb` that swaps `ConnectionHandler` for every `:integration`-tagged test. This requires real ActiveRecord, so it only activates when `V4_INTEGRATION_AVAILABLE` is true.

Add to `support.rb` after the `V4IntegrationHelper` module:

```ruby
if V4_INTEGRATION_AVAILABLE
  RSpec.configure do |config|
    config.around(:each, :integration) do |example|
      old_handler = ActiveRecord::Base.connection_handler
      new_handler = ActiveRecord::ConnectionAdapters::ConnectionHandler.new
      ActiveRecord::Base.connection_handler = new_handler

      # Re-establish the default connection on the fresh handler so the first
      # DB call in each test doesn't raise ConnectionNotEstablished.
      # Individual test before blocks may re-establish with different configs.
      default_config = V4IntegrationHelper.default_connection_config(
        tmp_dir: @__apartment_tmp_dir  # set by test's let(:tmp_dir) if present
      )
      ActiveRecord::Base.establish_connection(default_config) if default_config

      example.run
    ensure
      # Disconnect all pools on the temporary handler before discarding.
      begin
        new_handler&.clear_all_connections!
      rescue StandardError
        nil
      end
      ActiveRecord::Base.connection_handler = old_handler
    end
  end
end
```

**Note:** The `establish_connection` call in the `around` hook uses the engine-appropriate default config. Individual tests that need different configs (e.g., scenario tests) re-establish in their `before` blocks, which is fine — the `around` hook provides a safe default so no test accidentally hits a bare handler.

**Note:** Individual tests still call `establish_connection` in their `before` blocks — this is correct because each test re-establishes on the fresh handler. The `around` hook just ensures the handler itself is fresh.

- [ ] Add `around(:each, :integration)` hook to `support.rb`
- [ ] Run: `bundle exec appraisal rails-8.1-sqlite3 rspec spec/integration/v4/` (verify all pass with handler swap)
- [ ] Run: `DATABASE_ENGINE=postgresql bundle exec appraisal rails-8.1-postgresql rspec spec/integration/v4/`
- [ ] Run: `DATABASE_ENGINE=mysql bundle exec appraisal rails-8.1-mysql2 rspec spec/integration/v4/`
- [ ] Commit: `git commit -m "Add ConnectionHandler swap for hermetic integration tests"`

---

## Task 7: Scenario-Based Database Configs

**Files:**
- Create: `spec/integration/v4/scenarios/postgresql_schema.yml`
- Create: `spec/integration/v4/scenarios/postgresql_database.yml`
- Create: `spec/integration/v4/scenarios/mysql_database.yml`
- Create: `spec/integration/v4/scenarios/sqlite_file.yml`
- Modify: `spec/integration/v4/support.rb` (add scenario loading helpers)

### Implementation

Each YAML file defines the full scenario config:

`spec/integration/v4/scenarios/postgresql_schema.yml`:
```yaml
name: postgresql_schema
engine: postgresql
strategy: schema
adapter_class: PostgreSQLSchemaAdapter
default_tenant: public
connection:
  adapter: postgresql
  host: <%= ENV.fetch('PGHOST', '127.0.0.1') %>
  port: <%= ENV.fetch('PGPORT', '5432') %>
  username: <%= ENV.fetch('PGUSER', ENV.fetch('USER', nil)) %>
  password: <%= ENV.fetch('PGPASSWORD', nil) %>
  database: <%= ENV.fetch('APARTMENT_TEST_PG_DB', 'apartment_v4_test') %>
```

Similar files for other scenarios with appropriate values.

Add to `V4IntegrationHelper`:

```ruby
Scenario = Struct.new(:name, :engine, :strategy, :adapter_class, :default_tenant,
                       :connection, keyword_init: true)

def self.load_scenario(name)
  path = File.join(__dir__, 'scenarios', "#{name}.yml")
  raw = YAML.safe_load(ERB.new(File.read(path)).result, permitted_classes: [Symbol])
  Scenario.new(**raw.transform_keys(&:to_sym).merge(
    strategy: raw['strategy'].to_sym,
    connection: raw['connection'].transform_keys(&:to_s)
  ))
end

def self.scenarios_for_engine
  Dir[File.join(__dir__, 'scenarios', '*.yml')].filter_map do |path|
    name = File.basename(path, '.yml')
    scenario = load_scenario(name)
    scenario if scenario.engine == database_engine
  end
end

def self.each_scenario(&block)
  scenarios_for_engine.each(&block)
end
```

- [ ] Create scenario YAML files
- [ ] Add `Scenario` struct and loading helpers to `support.rb`
- [ ] Add a simple test that verifies scenarios load correctly for each engine
- [ ] Run: `bundle exec appraisal rails-8.1-sqlite3 rspec spec/integration/v4/` (verify no regressions)
- [ ] Commit: `git commit -m "Add scenario-based database configs for integration tests"`

---

## Task 8: Dummy App Upgrade to v4

**Files:**
- Modify: `spec/dummy/config/initializers/apartment.rb`
- Modify: `spec/dummy/config/application.rb`
- Modify: `spec/dummy/config/routes.rb`
- Modify: `spec/dummy/config/database.yml`
- Modify: `spec/dummy/config/environments/test.rb`
- Create: `spec/dummy/app/controllers/tenants_controller.rb`
- Create: `spec/integration/v4/request_lifecycle_spec.rb`

### Implementation

`spec/dummy/config/initializers/apartment.rb`:
```ruby
# frozen_string_literal: true

Apartment.configure do |config|
  config.tenant_strategy = :schema
  config.tenants_provider = -> { Company.pluck(:database) }
  config.default_tenant = 'public'
  config.excluded_models = ['Company']
  config.elevator = :subdomain
  config.schema_load_strategy = nil  # dummy app manages its own schema
  config.configure_postgres do |pg|
    pg.persistent_schemas = %w[public]
  end
end
```

`spec/dummy/config/application.rb`:
```ruby
# frozen_string_literal: true

require File.expand_path('boot', __dir__)

require 'active_model/railtie'
require 'active_record/railtie'
require 'action_controller/railtie'

Bundler.require
require 'apartment'

module Dummy
  class Application < Rails::Application
    config.load_defaults Rails::VERSION::STRING.to_f
    config.eager_load = false
    config.encoding = 'utf-8'
    config.filter_parameters += [:password]

    # v4 Railtie handles middleware insertion and Apartment.activate!
    # No manual middleware.use needed.
  end
end
```

`spec/dummy/config/database.yml`:
```yaml
test:
  adapter: postgresql
  database: apartment_postgresql_test
  host: <%= ENV.fetch('PGHOST', '127.0.0.1') %>
  port: <%= ENV.fetch('PGPORT', '5432') %>
  username: <%= ENV.fetch('PGUSER', ENV.fetch('USER', nil)) %>
  password: <%= ENV.fetch('PGPASSWORD', nil) %>
  schema_search_path: public
```

`spec/dummy/app/controllers/tenants_controller.rb`:
```ruby
# frozen_string_literal: true

class TenantsController < ActionController::Base
  def show
    render json: {
      tenant: Apartment::Tenant.current,
      user_count: User.count
    }
  end
end
```

`spec/dummy/config/routes.rb`:
```ruby
# frozen_string_literal: true

Dummy::Application.routes.draw do
  get '/tenant_info' => 'tenants#show'
  root to: 'tenants#show'
end
```

`spec/integration/v4/request_lifecycle_spec.rb`:
```ruby
# frozen_string_literal: true

# Request lifecycle tests require the dummy Rails app + real PostgreSQL.
# Run via: DATABASE_ENGINE=postgresql bundle exec appraisal rails-8.1-postgresql \
#   rspec spec/integration/v4/request_lifecycle_spec.rb

require 'spec_helper'

DUMMY_APP_AVAILABLE = begin
  require_relative '../../dummy/config/environment'
  require 'rack/test'
  true
rescue LoadError, StandardError => e
  warn "[request_lifecycle_spec] Skipping: #{e.message}"
  false
end

RSpec.describe('v4 Request lifecycle', :request_lifecycle,
               skip: (DUMMY_APP_AVAILABLE ? false : 'requires dummy Rails app + PostgreSQL')) do
  include Rack::Test::Methods

  def app
    Rails.application
  end

  before(:all) do
    # Ensure test schemas exist
    %w[acme widgets].each do |tenant|
      Apartment.adapter.create(tenant)
      Apartment::Tenant.switch(tenant) do
        ActiveRecord::Base.connection.create_table(:users, force: true) do |t|
          t.string :name
        end
      end
    rescue Apartment::TenantExists
      nil
    end
  end

  after(:all) do
    %w[acme widgets].each do |tenant|
      Apartment.adapter.drop(tenant)
    rescue StandardError
      nil
    end
  end

  after do
    Apartment::Current.reset
  end

  it 'elevator switches tenant based on subdomain' do
    header 'Host', 'acme.example.com'
    get '/tenant_info'
    expect(last_response).to be_ok
    body = JSON.parse(last_response.body)
    expect(body['tenant']).to eq('acme')
  end

  it 'data is isolated between tenants' do
    Apartment::Tenant.switch('acme') { User.create!(name: 'Alice') }

    header 'Host', 'acme.example.com'
    get '/tenant_info'
    expect(JSON.parse(last_response.body)['user_count']).to eq(1)

    header 'Host', 'widgets.example.com'
    get '/tenant_info'
    expect(JSON.parse(last_response.body)['user_count']).to eq(0)
  end

  it 'tenant context is cleaned up after request' do
    header 'Host', 'acme.example.com'
    get '/tenant_info'
    # After request completes, tenant should be reset to default
    expect(Apartment::Tenant.current).to eq('public')
  end

  it 'returns default tenant for requests without subdomain' do
    header 'Host', 'example.com'
    get '/tenant_info'
    expect(last_response).to be_ok
    body = JSON.parse(last_response.body)
    expect(body['tenant']).to eq('public')
  end
end
```

- [ ] Update `spec/dummy/config/initializers/apartment.rb` to v4 config
- [ ] Update `spec/dummy/config/application.rb` to remove v3 code
- [ ] Update `spec/dummy/config/database.yml` with ERB
- [ ] Update `spec/dummy/config/environments/test.rb` for modern Rails
- [ ] Update `spec/dummy/config/routes.rb`
- [ ] Create `spec/dummy/app/controllers/tenants_controller.rb`
- [ ] Create `spec/integration/v4/request_lifecycle_spec.rb`
- [ ] Add `gem 'rack-test'` to Gemfile if not present
- [ ] Run: `DATABASE_ENGINE=postgresql bundle exec appraisal rails-8.1-postgresql rspec spec/integration/v4/request_lifecycle_spec.rb`
- [ ] Run full integration suite: all three engines
- [ ] Commit: `git commit -m "Upgrade spec/dummy to v4, add request-lifecycle integration tests"`

---

## Task 9: Coverage + TestProf Tooling

**Files:**
- Modify: `Gemfile`
- Modify: `spec/spec_helper.rb`

### Implementation

Add to `Gemfile`:
```ruby
group :development, :test do
  gem 'simplecov', require: false
  gem 'test-prof', require: false
end
```

Add to top of `spec/spec_helper.rb` (must be before any other requires):
```ruby
if ENV['COVERAGE']
  require 'simplecov'
  SimpleCov.start do
    add_filter '/spec/'
    add_filter '/gemfiles/'
    add_group 'Adapters', 'lib/apartment/adapters'
    add_group 'Patches', 'lib/apartment/patches'
    add_group 'Config', 'lib/apartment/configs'
    add_group 'Core', 'lib/apartment'
    minimum_coverage 80
  end
end
```

- [ ] Add simplecov and test-prof to Gemfile
- [ ] Add SimpleCov configuration to spec_helper.rb
- [ ] Run: `bundle install`
- [ ] Run: `COVERAGE=1 bundle exec rspec spec/unit/` and verify coverage report
- [ ] Run: `FPROF=1 bundle exec appraisal rails-8.1-sqlite3 rspec spec/integration/v4/` to profile
- [ ] Add `coverage/` to `.gitignore`
- [ ] Commit: `git commit -m "Add SimpleCov and TestProf for coverage and profiling"`

---

## Task 10: Update CLAUDE.md and docs

**Files:**
- Modify: `CLAUDE.md`
- Modify: `lib/apartment/CLAUDE.md`
- Modify: `spec/CLAUDE.md`

Update all CLAUDE.md files to reflect:
- Railtie exists (remove "v3 only" notes)
- New test commands (coverage, profiling, request lifecycle)
- New files and their purposes
- Tenant name validation as a feature

- [ ] Update all three CLAUDE.md files
- [ ] Run: `bundle exec rspec spec/unit/` (sanity check)
- [ ] Run: all three engine integration suites
- [ ] Commit: `git commit -m "Update CLAUDE.md files for v4 Railtie and test infrastructure"`

---

## Execution Order

Tasks must be executed in order (each builds on the previous):

1. **Task 1** — TenantNameValidator (standalone, no dependencies)
2. **Task 2** — Wire validator into adapters + ConnectionHandling
3. **Task 3** — Config additions (schema_load_strategy)
4. **Task 4** — Schema loading in create (depends on Task 3)
5. **Task 5** — v4 Railtie (depends on Tasks 1-4)
6. **Task 6** — ConnectionHandler swap (test infra, independent of 1-5 but run after to verify)
7. **Task 7** — Scenario configs (test infra, depends on Task 6)
8. **Task 8** — Dummy app upgrade (depends on Task 5 Railtie + Task 6 handler swap)
9. **Task 9** — Coverage tooling (independent, last to avoid noise during development)
10. **Task 10** — Docs (last, after all code is final)
