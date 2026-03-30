# v4 Railtie + Test Infrastructure Overhaul — Design Spec

## Overview

This spec covers two tightly coupled deliverables: (1) a minimal v4 Railtie that makes Apartment work in a real Rails app, and (2) a test infrastructure overhaul that validates the Railtie works end-to-end and makes the existing test suite more hermetic and comprehensive.

**Primary goal:** After this work, CampusESP (and any Rails app) can boot with Apartment v4 by adding an initializer and having the Railtie wire everything up automatically.

**Secondary goal:** The test suite becomes scenario-driven, leak-proof, and instrumented with coverage and profiling tools.

## 1. Minimal v4 Railtie

### What it does

The Railtie is the bridge between `Apartment.configure` (user's initializer) and Rails boot. It does NOT configure Apartment — it wires up the result of configuration.

Three hooks, in Rails boot order:

1. **`config.after_initialize`** — After all initializers have run:
   - Guard: skip if `Apartment.config.nil?` (the `@config` ivar is nil until `Apartment.configure` is called — this is the correct predicate)
   - Warn if `ActiveSupport::IsolatedExecutionState.isolation_level` is `:thread` instead of `:fiber` — v4 requires fiber isolation for correct `CurrentAttributes` propagation to `load_async` threads (per v4 design doc)
   - Call `Apartment.activate!` (prepends ConnectionHandling on AR::Base)
   - Call `Apartment::Tenant.init` (processes excluded models)
   - Rescue `ActiveRecord::NoDatabaseError` for `db:create` compatibility (database may not exist yet)

2. **`config.app_middleware.use`** — Insert elevator middleware:
   - Only if `Apartment.config&.elevator` is set
   - Resolution mechanism: `"Apartment::Elevators::#{elevator.to_s.camelize}".constantize`. If the class doesn't exist, raises `ConfigurationError` with a clear message listing available elevators.
   - Passes `Apartment.config.elevator_options` to the elevator constructor

3. **`rake_tasks`** — Load v4 rake tasks:
   - `apartment:create` — creates all tenants from `tenants_provider`
   - `apartment:drop` — drops a named tenant
   - `apartment:migrate` — runs migrations for all tenants
   - `apartment:seed` — seeds all tenants
   - `apartment:rollback` — rolls back migrations for all tenants

### Schema loading during tenant creation

`AbstractAdapter#create` currently only runs DDL (`CREATE SCHEMA/DATABASE`). New tenants are empty. After this work, `create` also loads the schema into the new tenant:

```ruby
def create(tenant)
  run_callbacks(:create) do
    create_tenant(tenant)
    import_schema(tenant) if Apartment.config.schema_load_strategy
    seed(tenant) if Apartment.config.seed_after_create  # uses existing public seed method
    Instrumentation.instrument(:create, tenant: tenant)
  end
end
```

Schema loading strategy (new config option `schema_load_strategy`):
- `:schema_rb` (default) — `load(schema_file)` inside a tenant switch block
- `:sql` — `ActiveRecord::Tasks::DatabaseTasks.load_schema(config, :sql)` for `structure.sql`
- `nil` — skip schema loading (raw DDL only, current behavior)

The schema file path defaults to `db/schema.rb` (or `db/structure.sql`), configurable via `config.schema_file`.

**Note:** `seed_after_create` already exists in `Config` (added in Phase 1). No new config attribute needed for seeding.

**Failure handling for `import_schema`:** If schema loading fails after `create_tenant` DDL succeeded, the method raises `Apartment::SchemaLoadError` (wrapping the original exception). The tenant DDL artifact (schema/database/file) is left in place — the caller can decide to `drop` it. We do NOT auto-rollback because: (a) the tenant may be partially usable, (b) auto-drop could mask the real error, (c) the user may want to inspect the broken tenant. The error message includes both the tenant name and the original exception for clear debugging.

### User-facing configuration

Users configure Apartment in an initializer, then the Railtie wires it up:

```ruby
# config/initializers/apartment.rb
Apartment.configure do |config|
  config.tenant_strategy = :schema
  config.tenants_provider = -> { Company.pluck(:subdomain) }
  config.default_tenant = "public"
  config.excluded_models = %w[User Company]
  config.elevator = :subdomain
  config.configure_postgres do |pg|
    pg.persistent_schemas = %w[extensions]
  end
end
```

No other setup needed — the Railtie handles `activate!`, `init`, and middleware.

### File changes

- Replace `lib/apartment/railtie.rb` (currently v3, Zeitwerk-ignored) with v4 implementation
- Remove `railtie` from Zeitwerk ignore list in `lib/apartment.rb`
- Add `lib/apartment/tasks/v4.rake` for v4 rake tasks
- Add `schema_load_strategy` and `schema_file` to `Config`
- Add `import_schema` private method to `AbstractAdapter`

## 2. Tenant Name Validation

### Design

New module `Apartment::TenantNameValidator` — pure functions, no IO, no DB calls.

```ruby
module Apartment
  module TenantNameValidator
    module_function

    def validate!(name, strategy:, adapter_name: nil)
      validate_common!(name)
      case strategy
      when :schema
        validate_postgresql_identifier!(name)
      when :database_name
        case adapter_name
        when /mysql/, /trilogy/ then validate_mysql_database_name!(name)
        when /postgresql/, /postgis/ then validate_postgresql_identifier!(name)
        when /sqlite/ then validate_sqlite_path!(name)
        end
      end
      # :shard and :database_config strategies use common validation only.
      # Engine-specific validation is deferred until those strategies are implemented.
    end
  end
end
```

### Rules

**Common (all engines):**
- Must be a non-empty string
- No NUL bytes (`\x00`)
- No whitespace
- Max 255 characters (catch-all)

**PostgreSQL identifiers (schema names, database names):**
- Max 63 characters (NAMEDATALEN - 1)
- Must match `[a-zA-Z_][a-zA-Z0-9_-]*` — hyphens are allowed but require quoting. Our adapters already quote via `quote_table_name`, so hyphens are safe.
- Cannot start with `pg_` (reserved prefix)

**MySQL database names:**
- Max 64 characters
- Allowed: `[a-zA-Z0-9_$-]`
- Cannot start with a digit
- No `/`, `\`, `.` at end

**SQLite file paths:**
- No path traversal (`..`, `/` outside base directory)
- Filesystem-safe characters

### Enforcement mechanism

Validation is called from `AbstractAdapter`, not from subclasses. To guarantee it always runs, `AbstractAdapter` wraps the abstract `resolve_connection_config` in a template method:

```ruby
# AbstractAdapter
def validated_connection_config(tenant)
  TenantNameValidator.validate!(
    tenant,
    strategy: Apartment.config.tenant_strategy,
    adapter_name: base_config['adapter']
  )
  resolve_connection_config(tenant)
end
```

`ConnectionHandling#connection_pool` calls `validated_connection_config` instead of `resolve_connection_config` directly. `AbstractAdapter#create` also calls `validate!` before `create_tenant`. Subclasses continue to override `resolve_connection_config` — the validation wrapper is transparent.

### Where it's called

- `AbstractAdapter#create` — always validates before DDL. Raises `ConfigurationError` on invalid name.
- `AbstractAdapter#validated_connection_config` — called by `ConnectionHandling`. In-memory only.
- NOT called during `switch` or `switch!` — these just set `Current.tenant` and the pool lookup handles the rest. The validation happens when the pool is first created (via `validated_connection_config` in `ConnectionHandling`).

### What it's NOT

- NOT an existence check (no DB query to see if tenant exists)
- NOT a `tenant_presence_check` (the v3 setting that was turned off for performance)
- Just a format/safety check on the string itself

## 3. ConnectionHandler Swap in Tests

### Problem

Current integration tests share a single `ActiveRecord::Base.connection_handler`. Pools registered by one test leak into the next. `Apartment.clear_config` deregisters shards but doesn't replace the handler. This causes subtle inter-test dependencies.

### Solution

Adopt the `activerecord-tenanted` pattern: swap in a fresh `ConnectionHandler` per test.

In `spec/integration/v4/support.rb`, add an RSpec configuration hook:

```ruby
RSpec.configure do |config|
  config.around(:each, :integration) do |example|
    old_handler = ActiveRecord::Base.connection_handler
    new_handler = ActiveRecord::ConnectionAdapters::ConnectionHandler.new
    ActiveRecord::Base.connection_handler = new_handler
    # Re-establish the default connection on the fresh handler
    ActiveRecord::Base.establish_connection(...)
    example.run
  ensure
    # Disconnect all pools on the temporary handler before discarding it.
    # Without this, connections opened during the test remain open on the
    # database server until the process exits or the GC collects them.
    new_handler&.clear_all_connections!
    ActiveRecord::Base.connection_handler = old_handler
  end
end
```

This ensures:
- Each test gets a pristine handler with no leftover shard registrations
- Pool leakage between tests is impossible
- `Apartment.clear_config` in `after` blocks becomes a secondary cleanup, not the only defense

### Impact on existing tests

All `spec/integration/v4/` tests already use the `:integration` tag. The swap is transparent — tests don't need to change. The `before`/`after` blocks that call `Apartment.clear_config` remain as belt-and-suspenders cleanup.

## 4. Scenario-Based Database Configs

### Problem

`V4IntegrationHelper.default_connection_config` returns one config per engine. Tests can't easily run the same assertions against different strategies (e.g., PG schema vs PG database-per-tenant).

### Solution

Add scenario configs as YAML files:

```
spec/integration/v4/scenarios/
├── postgresql_schema.yml    # schema-per-tenant (most common PG config)
├── postgresql_database.yml  # database-per-tenant on PG
├── mysql_database.yml       # database-per-tenant on MySQL
└── sqlite_file.yml          # file-per-tenant
```

Each YAML defines: adapter, strategy, connection params, default_tenant, and any adapter-specific config (persistent_schemas, environmentify, etc.).

`V4IntegrationHelper` gains:

```ruby
def self.scenarios_for_engine
  # Returns available scenarios for current DATABASE_ENGINE
end

def self.with_scenario(name)
  # Loads scenario config
  # Configures Apartment
  # Builds adapter
  # Yields
  # Cleans up
end

def self.each_scenario(&block)
  # Iterates over all scenarios for current engine
  # Used for cross-scenario test generation
end
```

Tests that should run against multiple scenarios use:

```ruby
V4IntegrationHelper.each_scenario do |scenario|
  context "with #{scenario.name}" do
    before { scenario.setup! }
    after { scenario.teardown! }

    it "isolates data" do
      # ...
    end
  end
end
```

Tests that are engine-specific (e.g., PG schema search_path) continue to use the `if: V4IntegrationHelper.postgresql?` guard and configure directly.

## 5. Dummy App Upgrade to v4

### Current state

`spec/dummy/` is a v3 Rails app with:
- Company (excluded model), User, Book models
- PostgreSQL database.yml (`apartment_postgresql_test`)
- v3 `Apartment.configure` initializer
- Subdomain elevator middleware
- Migrations, seeds, schema.rb

### Changes

1. **Replace initializer** — `config/initializers/apartment.rb` uses v4 `Apartment.configure` block
2. **Railtie wires it up** — the v4 Railtie handles `activate!`, `init`, middleware
3. **Add a test controller** — `TenantsController#show` returns `{ tenant: Apartment::Tenant.current, user_count: User.count }` as JSON
4. **Add route** — `get '/tenant_info' => 'tenants#show'`
5. **Update database.yml** — ensure it works with the v4 config system
6. **Update config/application.rb** — remove v3-specific requires, load v4

### Request-lifecycle test

New file `spec/integration/v4/request_lifecycle_spec.rb`:

```ruby
# Boots the dummy app, sends HTTP requests through the elevator,
# verifies tenant switching + data isolation in the response.

RSpec.describe 'Request lifecycle', :request_lifecycle do
  include Rack::Test::Methods

  def app
    Dummy::Application
  end

  it 'elevator switches tenant based on subdomain' do
    header 'Host', 'acme.example.com'
    get '/tenant_info'
    expect(last_response).to be_ok
    body = JSON.parse(last_response.body)
    expect(body['tenant']).to eq('acme')
  end

  it 'data is isolated between tenants' do
    # Create user in tenant A
    Apartment::Tenant.switch('acme') { User.create!(name: 'Alice') }

    # Request tenant A — should see 1 user
    header 'Host', 'acme.example.com'
    get '/tenant_info'
    expect(JSON.parse(last_response.body)['user_count']).to eq(1)

    # Request tenant B — should see 0 users
    header 'Host', 'widgets.example.com'
    get '/tenant_info'
    expect(JSON.parse(last_response.body)['user_count']).to eq(0)
  end

  it 'tenant context is cleaned up after request' do
    header 'Host', 'acme.example.com'
    get '/tenant_info'
    expect(Apartment::Tenant.current).to eq(Apartment.config.default_tenant)
  end
end
```

These tests require real PostgreSQL (the dummy app uses PG). They run via:
```bash
DATABASE_ENGINE=postgresql bundle exec appraisal rails-8.1-postgresql rspec spec/integration/v4/request_lifecycle_spec.rb
```

## 6. Coverage + TestProf

### SimpleCov

Add to `Gemfile` development group:
```ruby
gem 'simplecov', require: false
```

Configure in `spec/spec_helper.rb`:
```ruby
if ENV['COVERAGE']
  require 'simplecov'
  SimpleCov.start do
    add_filter '/spec/'
    add_group 'Adapters', 'lib/apartment/adapters'
    add_group 'Patches', 'lib/apartment/patches'
    add_group 'Core', 'lib/apartment'
    minimum_coverage 80
  end
end
```

Run: `COVERAGE=1 bundle exec rspec spec/unit/`

### TestProf

Add to `Gemfile` development group:
```ruby
gem 'test-prof', require: false
```

Initial usage is **profiling only** — identify slow tests and expensive setup patterns:

```bash
# Profile test suite to find slow examples and expensive let/before blocks
FPROF=1 bundle exec rspec spec/integration/v4/
EVENT_PROF=sql.active_record bundle exec rspec spec/integration/v4/
```

`let_it_be` and `before_all` are available but deferred until profiling reveals specific tests where they'd help. Don't pre-optimize — add them where profiling shows setup cost dominates.

## File Map

### New files

| File | Purpose |
|------|---------|
| `lib/apartment/railtie.rb` | v4 Railtie (replaces v3) |
| `lib/apartment/tasks/v4.rake` | v4 rake tasks |
| `lib/apartment/tenant_name_validator.rb` | Tenant name format validation |
| `spec/unit/tenant_name_validator_spec.rb` | Validator unit tests |
| `spec/unit/railtie_spec.rb` | Railtie hook tests |
| `spec/integration/v4/request_lifecycle_spec.rb` | Dummy app request tests |
| `spec/integration/v4/scenarios/*.yml` | Database config scenarios |

### Modified files

| File | Change |
|------|--------|
| `lib/apartment.rb` | Remove `railtie` from Zeitwerk ignore, add schema_load_strategy to config |
| `lib/apartment/config.rb` | Add `schema_load_strategy`, `schema_file` options |
| `lib/apartment/adapters/abstract_adapter.rb` | Add `import_schema`, `validated_connection_config` wrapper, call validator in `create` |
| `lib/apartment/patches/connection_handling.rb` | Call `validated_connection_config` instead of `resolve_connection_config` |
| `spec/integration/v4/support.rb` | ConnectionHandler swap, scenario loading, `with_scenario` helper |
| `spec/dummy/config/initializers/apartment.rb` | v4 configure block |
| `spec/dummy/config/application.rb` | Remove v3 requires |
| `spec/dummy/app/controllers/tenants_controller.rb` | New test controller |
| `spec/dummy/config/routes.rb` | Add tenant_info route |
| `Gemfile` | Add simplecov, test-prof |
