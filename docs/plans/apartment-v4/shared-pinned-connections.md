# Shared Pinned Model Connections — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make pinned model connection strategy depend on whether the database engine supports cross-schema/database queries, eliminating unnecessary connection pools and enabling transactional integrity between pinned and tenant models.

**Architecture:** Dual-path `process_pinned_model`: shared path (qualify table name, skip `establish_connection`) for PG schema and MySQL single-server; separate path (`establish_connection` with `pinned_model_config`) for PG database-per-tenant, SQLite, and apps that opt out via `force_separate_pinned_pool`. `ConnectionHandling#connection_pool` conditionally routes pinned models through tenant pools when shared connections are supported.

**Tech Stack:** Ruby, ActiveRecord, RSpec, Appraisal (multi-Rails testing)

**Design spec:** `docs/designs/v4-shared-pinned-connections.md`

**Attribution:** Commits deriving from [rails-on-services/apartment#367](https://github.com/rails-on-services/apartment/pull/367) include `Co-Authored-By: henkesn <14108170+henkesn@users.noreply.github.com>`.

---

### Task 1: Add `force_separate_pinned_pool` config option

**Files:**
- Modify: `lib/apartment/config.rb:17-53` (attr_accessor, default, validation)
- Modify: `spec/unit/config_spec.rb` (default + validation tests)

- [ ] **Step 1: Write the failing tests**

In `spec/unit/config_spec.rb`, add within the `describe 'defaults'` block:

```ruby
it { expect(config.force_separate_pinned_pool).to(be(false)) }
```

Add a new describe block after the existing validation tests:

```ruby
describe '#force_separate_pinned_pool' do
  it 'accepts true' do
    config.tenant_strategy = :schema
    config.tenants_provider = -> { [] }
    config.force_separate_pinned_pool = true
    expect { config.validate! }.not_to(raise_error)
  end

  it 'accepts false' do
    config.tenant_strategy = :schema
    config.tenants_provider = -> { [] }
    config.force_separate_pinned_pool = false
    expect { config.validate! }.not_to(raise_error)
  end

  it 'rejects non-boolean values' do
    config.tenant_strategy = :schema
    config.tenants_provider = -> { [] }
    config.force_separate_pinned_pool = 'yes'
    expect { config.validate! }.to(raise_error(Apartment::ConfigurationError, /force_separate_pinned_pool/))
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/unit/config_spec.rb --format documentation`
Expected: 3 failures (unknown attribute, missing validation)

- [ ] **Step 3: Implement the config option**

In `lib/apartment/config.rb`:

Add `force_separate_pinned_pool` to the `attr_accessor` list on line 17:

```ruby
attr_accessor :tenants_provider, :default_tenant,
              :tenant_pool_size, :pool_idle_timeout, :max_total_connections,
              :seed_after_create, :seed_data_file,
              :schema_load_strategy, :schema_file,
              :parallel_migration_threads,
              :elevator, :elevator_options,
              :tenant_not_found_handler, :active_record_log, :sql_query_tags,
              :shard_key_prefix,
              :migration_role, :app_role, :schema_cache_per_tenant, :check_pending_migrations,
              :force_separate_pinned_pool
```

Add default in `initialize` (after `@check_pending_migrations = true`):

```ruby
@force_separate_pinned_pool = false
```

Add validation in `validate!` (after the `check_pending_migrations` validation block):

```ruby
unless [true, false].include?(@force_separate_pinned_pool)
  raise(ConfigurationError,
        "force_separate_pinned_pool must be true or false, got: #{@force_separate_pinned_pool.inspect}")
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/unit/config_spec.rb --format documentation`
Expected: all pass

- [ ] **Step 5: Commit**

```bash
git add lib/apartment/config.rb spec/unit/config_spec.rb
git commit -m "Add force_separate_pinned_pool config option

New boolean (default false) on Apartment::Config. Escape hatch for
multi-server MySQL topologies and apps that rely on pinned model
writes surviving tenant transaction rollbacks.

Co-Authored-By: henkesn <14108170+henkesn@users.noreply.github.com>
Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Add `shared_pinned_connection?` and `qualify_pinned_table_name` to AbstractAdapter

**Files:**
- Modify: `lib/apartment/adapters/abstract_adapter.rb:96-130,180-186`
- Modify: `spec/unit/adapters/abstract_adapter_spec.rb:322-397`

- [ ] **Step 1: Write the failing tests**

In `spec/unit/adapters/abstract_adapter_spec.rb`, add a new describe block before the existing `#process_pinned_models` block (after line 321):

```ruby
describe '#shared_pinned_connection?' do
  it 'returns false by default (safe fallback)' do
    expect(adapter.shared_pinned_connection?).to(be(false))
  end
end

describe '#qualify_pinned_table_name' do
  it 'raises NotImplementedError on the abstract class' do
    klass = Class.new(ActiveRecord::Base)
    expect { adapter.qualify_pinned_table_name(klass) }.to(raise_error(
      NotImplementedError, /qualify_pinned_table_name must be implemented/
    ))
  end
end

describe '#explicit_table_name? (private)' do
  it 'returns false when @table_name is not set' do
    klass = Class.new(ActiveRecord::Base)
    stub_const('NoTableName', klass)
    expect(adapter.send(:explicit_table_name?, klass)).to(be(false))
  end

  it 'returns false when cached equals computed (convention naming)' do
    klass = Class.new(ActiveRecord::Base)
    stub_const('ConventionModel', klass)
    # Trigger lazy computation so @table_name is set
    allow(klass).to(receive(:compute_table_name).and_return('convention_models'))
    klass.instance_variable_set(:@table_name, 'convention_models')
    expect(adapter.send(:explicit_table_name?, klass)).to(be(false))
  end

  it 'returns true when cached differs from computed (explicit assignment)' do
    klass = Class.new(ActiveRecord::Base)
    stub_const('ExplicitModel', klass)
    allow(klass).to(receive(:compute_table_name).and_return('explicit_models'))
    klass.instance_variable_set(:@table_name, 'custom_table')
    expect(adapter.send(:explicit_table_name?, klass)).to(be(true))
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/unit/adapters/abstract_adapter_spec.rb --format documentation`
Expected: failures for `shared_pinned_connection?`, `qualify_pinned_table_name`, `explicit_table_name?`

- [ ] **Step 3: Implement the methods**

In `lib/apartment/adapters/abstract_adapter.rb`, add after the `seed` method (after line 97) and before `process_pinned_models`:

```ruby
# Whether pinned models can share the tenant's connection pool using
# qualified table names. When true, process_pinned_model qualifies the
# table name instead of calling establish_connection.
#
# Combines engine capability with config override. Returns false by
# default (safe fallback — separate pool). Subclasses override to
# return true for engines that support cross-schema/database queries.
def shared_pinned_connection?
  false
end

# Qualify a pinned model's table_name so it targets the default
# tenant's tables from any tenant connection. Subclasses must
# implement when shared_pinned_connection? returns true.
def qualify_pinned_table_name(_klass)
  raise(NotImplementedError,
        "#{self.class}#qualify_pinned_table_name must be implemented when shared_pinned_connection? is true")
end
```

In the `private` section (after `base_config`, around line 186), add:

```ruby
# Detect whether a model has an explicit self.table_name = assignment
# (as opposed to Rails' lazy convention computation).
def explicit_table_name?(klass)
  return false unless klass.instance_variable_defined?(:@table_name)

  cached = klass.instance_variable_get(:@table_name)
  computed = klass.send(:compute_table_name)
  cached != computed
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/unit/adapters/abstract_adapter_spec.rb --format documentation`
Expected: all pass

- [ ] **Step 5: Commit**

```bash
git add lib/apartment/adapters/abstract_adapter.rb spec/unit/adapters/abstract_adapter_spec.rb
git commit -m "Add shared_pinned_connection?, qualify_pinned_table_name, explicit_table_name?

Template methods on AbstractAdapter for the dual-path pinned model
strategy. shared_pinned_connection? returns false by default (safe
fallback). qualify_pinned_table_name raises NotImplementedError as
guard. explicit_table_name? detects models with self.table_name =.

Co-Authored-By: henkesn <14108170+henkesn@users.noreply.github.com>
Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Implement `shared_pinned_connection?` and `qualify_pinned_table_name` in PostgresqlSchemaAdapter

**Files:**
- Modify: `lib/apartment/adapters/postgresql_schema_adapter.rb:14-21`
- Modify: `spec/unit/adapters/postgresql_schema_adapter_spec.rb`

- [ ] **Step 1: Write the failing tests**

In `spec/unit/adapters/postgresql_schema_adapter_spec.rb`, add after the `describe 'inheritance'` block:

```ruby
describe '#shared_pinned_connection?' do
  it 'returns true (schemas share a catalog)' do
    expect(adapter.shared_pinned_connection?).to(be(true))
  end

  it 'returns false when force_separate_pinned_pool is true' do
    reconfigure { |c| c.force_separate_pinned_pool = true }
    expect(adapter.shared_pinned_connection?).to(be(false))
  end
end

describe '#qualify_pinned_table_name' do
  it 'qualifies convention-named model via table_name_prefix + reset_table_name' do
    klass = Class.new(ActiveRecord::Base)
    stub_const('DelayedJob', klass)

    expect(klass).to(receive(:table_name_prefix=).with('public.'))
    expect(klass).to(receive(:reset_table_name))

    adapter.qualify_pinned_table_name(klass)
  end

  it 'qualifies explicit table_name via direct assignment' do
    klass = Class.new(ActiveRecord::Base)
    stub_const('ExplicitPinned', klass)
    klass.instance_variable_set(:@table_name, 'custom_jobs')
    allow(klass).to(receive(:compute_table_name).and_return('explicit_pinneds'))
    allow(klass).to(receive(:table_name).and_return('custom_jobs'))

    expect(klass).to(receive(:table_name=).with('public.custom_jobs'))
    expect(klass).not_to(receive(:table_name_prefix=))

    adapter.qualify_pinned_table_name(klass)
  end

  it 'strips existing schema prefix before re-qualifying' do
    klass = Class.new(ActiveRecord::Base)
    stub_const('RequalifyPinned', klass)
    klass.instance_variable_set(:@table_name, 'old_schema.jobs')
    allow(klass).to(receive(:compute_table_name).and_return('requalify_pinneds'))
    allow(klass).to(receive(:table_name).and_return('old_schema.jobs'))

    expect(klass).to(receive(:table_name=).with('public.jobs'))

    adapter.qualify_pinned_table_name(klass)
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/unit/adapters/postgresql_schema_adapter_spec.rb --format documentation`
Expected: failures for `shared_pinned_connection?` and `qualify_pinned_table_name`

- [ ] **Step 3: Implement the methods**

In `lib/apartment/adapters/postgresql_schema_adapter.rb`, add after line 14 (`class PostgresqlSchemaAdapter < AbstractAdapter`):

```ruby
def shared_pinned_connection?
  !Apartment.config.force_separate_pinned_pool
end

def qualify_pinned_table_name(klass)
  if explicit_table_name?(klass)
    klass.instance_variable_set(:@apartment_original_table_name, klass.table_name)
    klass.instance_variable_set(:@apartment_qualification_path, :explicit)
    table = klass.table_name.sub(/\A[^.]+\./, '')
    klass.table_name = "#{default_tenant}.#{table}"
  else
    klass.instance_variable_set(:@apartment_qualification_path, :convention)
    klass.table_name_prefix = "#{default_tenant}."
    klass.reset_table_name
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/unit/adapters/postgresql_schema_adapter_spec.rb --format documentation`
Expected: all pass

- [ ] **Step 5: Commit**

```bash
git add lib/apartment/adapters/postgresql_schema_adapter.rb spec/unit/adapters/postgresql_schema_adapter_spec.rb
git commit -m "Implement shared_pinned_connection? and qualify_pinned_table_name for PG schema

PostgresqlSchemaAdapter returns true for shared_pinned_connection?
(schemas share a catalog). qualify_pinned_table_name uses hybrid
strategy: table_name_prefix for convention-named models, direct
table_name= for explicit self.table_name assignments.

Co-Authored-By: henkesn <14108170+henkesn@users.noreply.github.com>
Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Implement `shared_pinned_connection?` and `qualify_pinned_table_name` in Mysql2Adapter

**Files:**
- Modify: `lib/apartment/adapters/mysql2_adapter.rb`
- Modify: `spec/unit/adapters/mysql2_adapter_spec.rb`

- [ ] **Step 1: Write the failing tests**

In `spec/unit/adapters/mysql2_adapter_spec.rb`, add inside the `RSpec.shared_examples('a MySQL adapter')` block, after the `describe '#resolve_connection_config'` block:

```ruby
describe '#shared_pinned_connection?' do
  it 'returns true (MySQL supports cross-database queries on same server)' do
    expect(adapter.shared_pinned_connection?).to(be(true))
  end

  it 'returns false when force_separate_pinned_pool is true' do
    reconfigure(force_separate_pinned_pool: true)
    expect(adapter.shared_pinned_connection?).to(be(false))
  end
end

describe '#qualify_pinned_table_name' do
  it 'qualifies convention-named model with database name from base_config' do
    klass = Class.new(ActiveRecord::Base)
    stub_const('MysqlPinned', klass)

    expect(klass).to(receive(:table_name_prefix=).with('myapp.'))
    expect(klass).to(receive(:reset_table_name))

    adapter.qualify_pinned_table_name(klass)
  end

  it 'qualifies explicit table_name with database name from base_config' do
    klass = Class.new(ActiveRecord::Base)
    stub_const('MysqlExplicit', klass)
    klass.instance_variable_set(:@table_name, 'custom_jobs')
    allow(klass).to(receive(:compute_table_name).and_return('mysql_explicits'))
    allow(klass).to(receive(:table_name).and_return('custom_jobs'))

    expect(klass).to(receive(:table_name=).with('myapp.custom_jobs'))

    adapter.qualify_pinned_table_name(klass)
  end

  it 'strips existing database prefix before re-qualifying' do
    klass = Class.new(ActiveRecord::Base)
    stub_const('MysqlRequalify', klass)
    klass.instance_variable_set(:@table_name, 'old_db.jobs')
    allow(klass).to(receive(:compute_table_name).and_return('mysql_requalifies'))
    allow(klass).to(receive(:table_name).and_return('old_db.jobs'))

    expect(klass).to(receive(:table_name=).with('myapp.jobs'))

    adapter.qualify_pinned_table_name(klass)
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/unit/adapters/mysql2_adapter_spec.rb --format documentation`
Expected: failures for `shared_pinned_connection?` and `qualify_pinned_table_name`

- [ ] **Step 3: Implement the methods**

In `lib/apartment/adapters/mysql2_adapter.rb`, add after line 11 (`class Mysql2Adapter < AbstractAdapter`):

```ruby
def shared_pinned_connection?
  !Apartment.config.force_separate_pinned_pool
end

def qualify_pinned_table_name(klass)
  db_name = base_config['database']

  if explicit_table_name?(klass)
    klass.instance_variable_set(:@apartment_original_table_name, klass.table_name)
    klass.instance_variable_set(:@apartment_qualification_path, :explicit)
    table = klass.table_name.sub(/\A[^.]+\./, '')
    klass.table_name = "#{db_name}.#{table}"
  else
    klass.instance_variable_set(:@apartment_qualification_path, :convention)
    klass.table_name_prefix = "#{db_name}."
    klass.reset_table_name
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/unit/adapters/mysql2_adapter_spec.rb --format documentation`
Expected: all pass

- [ ] **Step 5: Run TrilogyAdapter tests to verify inheritance**

Run: `bundle exec rspec spec/unit/adapters/mysql2_adapter_spec.rb --format documentation`
Expected: Trilogy specs pass (inherits from Mysql2Adapter)

- [ ] **Step 6: Commit**

```bash
git add lib/apartment/adapters/mysql2_adapter.rb spec/unit/adapters/mysql2_adapter_spec.rb
git commit -m "Implement shared_pinned_connection? and qualify_pinned_table_name for MySQL

Mysql2Adapter returns true for shared_pinned_connection? (MySQL
supports cross-database queries). qualify_pinned_table_name uses
base_config['database'] as qualifier. TrilogyAdapter inherits both.

Co-Authored-By: henkesn <14108170+henkesn@users.noreply.github.com>
Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Rewrite `process_pinned_model` with dual-path logic and `pinned_model_config`

**Files:**
- Modify: `lib/apartment/adapters/abstract_adapter.rb:108-130,183-186`
- Modify: `spec/unit/adapters/abstract_adapter_spec.rb:323-397`

- [ ] **Step 1: Write the failing tests**

Replace the entire `describe '#process_pinned_models'` block in `spec/unit/adapters/abstract_adapter_spec.rb` with:

```ruby
describe '#process_pinned_models' do
  context 'when shared_pinned_connection? is false (separate pool)' do
    it 'calls establish_connection with pinned_model_config' do
      model_class = Class.new(ActiveRecord::Base) do
        include Apartment::Model
      end
      stub_const('SeparatePinned', model_class)
      allow(model_class).to(receive(:table_name).and_return('separate_pinned'))
      allow(model_class).to(receive(:table_name=))

      SeparatePinned.pin_tenant

      # Schema strategy: pinned_model_config includes schema_search_path
      expected_config = {
        'adapter' => 'postgresql', 'host' => 'localhost',
        'schema_search_path' => '"public"'
      }
      expect(model_class).to(receive(:establish_connection)) do |arg|
        expect(arg).to(eq(expected_config))
      end

      adapter.process_pinned_models
    end

    it 'includes persistent schemas in pinned_model_config search_path' do
      model_class = Class.new(ActiveRecord::Base) do
        include Apartment::Model
      end
      stub_const('PersistentPinned', model_class)
      allow(model_class).to(receive(:table_name).and_return('persistent_pinned'))
      allow(model_class).to(receive(:table_name=))

      PersistentPinned.pin_tenant

      Apartment.configure do |c|
        c.tenant_strategy = :schema
        c.tenants_provider = -> { %w[t1 t2] }
        c.default_tenant = 'public'
        c.force_separate_pinned_pool = true
        c.configure_postgres { |pg| pg.persistent_schemas = %w[shared ext] }
      end

      expected_config = {
        'adapter' => 'postgresql', 'host' => 'localhost',
        'schema_search_path' => '"public","shared","ext"'
      }
      expect(model_class).to(receive(:establish_connection)) do |arg|
        expect(arg).to(eq(expected_config))
      end

      adapter.process_pinned_models
    end

    it 'uses plain base_config for database_name strategy' do
      model_class = Class.new(ActiveRecord::Base) do
        include Apartment::Model
      end
      stub_const('DbSeparatePinned', model_class)
      allow(model_class).to(receive(:table_name).and_return('db_separate_pinned'))

      DbSeparatePinned.pin_tenant

      reconfigure(tenant_strategy: :database_name)

      expected_config = { 'adapter' => 'postgresql', 'host' => 'localhost' }
      expect(model_class).to(receive(:establish_connection)) do |arg|
        expect(arg).to(eq(expected_config))
      end

      adapter.process_pinned_models
    end

    it 'does not call qualify_pinned_table_name' do
      model_class = Class.new(ActiveRecord::Base) do
        include Apartment::Model
      end
      stub_const('NoQualifyPinned', model_class)
      allow(model_class).to(receive(:table_name).and_return('no_qualify_pinned'))
      allow(model_class).to(receive(:establish_connection))

      NoQualifyPinned.pin_tenant

      expect(adapter).not_to(receive(:qualify_pinned_table_name))
      adapter.process_pinned_models
    end
  end

  context 'when shared_pinned_connection? is true (shared pool)' do
    before do
      allow(adapter).to(receive(:shared_pinned_connection?).and_return(true))
      allow(adapter).to(receive(:qualify_pinned_table_name))
    end

    it 'does not call establish_connection' do
      model_class = Class.new(ActiveRecord::Base) do
        include Apartment::Model
      end
      stub_const('SharedPinned', model_class)
      allow(model_class).to(receive(:table_name).and_return('shared_pinned'))

      SharedPinned.pin_tenant

      expect(model_class).not_to(receive(:establish_connection))
      adapter.process_pinned_models
    end

    it 'calls qualify_pinned_table_name' do
      model_class = Class.new(ActiveRecord::Base) do
        include Apartment::Model
      end
      stub_const('QualifyPinned', model_class)
      allow(model_class).to(receive(:table_name).and_return('qualify_pinned'))

      QualifyPinned.pin_tenant

      expect(adapter).to(receive(:qualify_pinned_table_name).with(model_class))
      adapter.process_pinned_models
    end
  end

  it 'skips models already processed (idempotent via @apartment_pinned_processed)' do
    model_class = Class.new(ActiveRecord::Base) do
      include Apartment::Model
    end
    stub_const('AlreadyPinned', model_class)
    allow(model_class).to(receive(:table_name).and_return('already_pinned'))
    allow(model_class).to(receive(:table_name=))

    AlreadyPinned.pin_tenant

    # First call processes the model
    allow(model_class).to(receive(:establish_connection))
    adapter.process_pinned_models

    # Second call skips — @apartment_pinned_processed is set
    expect(model_class).not_to(receive(:establish_connection))
    adapter.process_pinned_models
  end

  it 'does nothing when no models are pinned' do
    expect { adapter.process_pinned_models }.not_to(raise_error)
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/unit/adapters/abstract_adapter_spec.rb --format documentation`
Expected: failures in `process_pinned_models` tests

- [ ] **Step 3: Implement the dual-path process_pinned_model and pinned_model_config**

Replace the `process_pinned_model` method in `lib/apartment/adapters/abstract_adapter.rb` (lines 108-130) with:

```ruby
# Process a single pinned model. Called by process_pinned_models (batch)
# and by Apartment::Model.pin_tenant (when activated? is true).
#
# When shared_pinned_connection? is true, qualifies the table name so
# the model uses the tenant's pool (preserving transactional integrity).
# Otherwise, establishes a separate connection pool (required when
# cross-database queries are impossible).
def process_pinned_model(klass)
  return if klass.instance_variable_get(:@apartment_pinned_processed)

  if shared_pinned_connection?
    qualify_pinned_table_name(klass)
  else
    klass.establish_connection(pinned_model_config)
  end

  klass.instance_variable_set(:@apartment_pinned_processed, true)
end
```

Add `pinned_model_config` in the private section (after `base_config`):

```ruby
# Connection config for pinned models on the separate-pool path.
# For schema strategy, pins schema_search_path to the default tenant
# (plus persistent schemas) so FK constraints resolve correctly.
# For database strategies, returns base_config unchanged.
def pinned_model_config
  config = base_config
  return config unless Apartment.config.tenant_strategy == :schema

  persistent = Apartment.config.postgres_config&.persistent_schemas || []
  search_path = [default_tenant, *persistent].map { |s| %("#{s}") }.join(',')
  config.merge('schema_search_path' => search_path)
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/unit/adapters/abstract_adapter_spec.rb --format documentation`
Expected: all pass

- [ ] **Step 5: Commit**

```bash
git add lib/apartment/adapters/abstract_adapter.rb spec/unit/adapters/abstract_adapter_spec.rb
git commit -m "Rewrite process_pinned_model with dual-path logic

Shared path: qualify table name, skip establish_connection.
Separate path: establish_connection with pinned_model_config
(includes schema_search_path for PG schema strategy FK fix).
Ivar renamed to @apartment_pinned_processed.

Co-Authored-By: henkesn <14108170+henkesn@users.noreply.github.com>
Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Update `clear_config` teardown and ivar references

**Files:**
- Modify: `lib/apartment.rb:120-134`
- Modify: `spec/unit/adapters/abstract_adapter_spec.rb` (idempotency test comment, already done in Task 5)

- [ ] **Step 1: Update `clear_config` in `lib/apartment.rb`**

Replace the `clear_config` method (lines 121-134) with:

```ruby
# Reset all configuration and stop background tasks.
def clear_config
  teardown_old_state
  # Reset per-model processing flags and undo table name qualification.
  @pinned_models&.each do |klass|
    next unless klass.instance_variable_defined?(:@apartment_pinned_processed)

    # Restore table name based on which qualification path was used.
    case klass.instance_variable_get(:@apartment_qualification_path)
    when :convention
      klass.table_name_prefix = ''
      klass.reset_table_name
    when :explicit
      original = klass.instance_variable_get(:@apartment_original_table_name)
      klass.table_name = original if original
    end

    klass.remove_instance_variable(:@apartment_pinned_processed)
    klass.remove_instance_variable(:@apartment_qualification_path) if klass.instance_variable_defined?(:@apartment_qualification_path)
    klass.remove_instance_variable(:@apartment_original_table_name) if klass.instance_variable_defined?(:@apartment_original_table_name)
  end
  @config = nil
  @pool_manager = nil
  @pool_reaper = nil
  @pinned_models = nil
  @activated = false
end
```

- [ ] **Step 2: Run full unit suite to verify nothing broke**

Run: `bundle exec rspec spec/unit/ --format progress`
Expected: all pass (613+ examples, 0 failures)

- [ ] **Step 3: Run `rg apartment_connection_established` to find remaining references**

Run: `rg apartment_connection_established --type ruby`
Expected: no matches in `lib/` or `spec/` (only docs/plans which are historical)

- [ ] **Step 4: Commit**

```bash
git add lib/apartment.rb
git commit -m "Update clear_config teardown for new pinned model ivars

Restores table name qualification on clear_config: convention path
resets table_name_prefix + reset_table_name; explicit path restores
original table_name. Cleans up all three ivars (@apartment_pinned_processed,
@apartment_qualification_path, @apartment_original_table_name).

Co-Authored-By: henkesn <14108170+henkesn@users.noreply.github.com>
Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Modify ConnectionHandling to conditionally route pinned models

**Files:**
- Modify: `lib/apartment/patches/connection_handling.rb:20-24`
- Modify: `spec/unit/patches/connection_handling_spec.rb:47-49` (mock_adapter default)
- Modify: `spec/unit/patches/connection_handling_spec.rb:269-349` (pinned model bypass + Tenant.each)

- [ ] **Step 1: Add `shared_pinned_connection?` to the default mock_adapter**

In `spec/unit/patches/connection_handling_spec.rb`, update the `let(:mock_adapter)` (line 47) to include the new method:

```ruby
let(:mock_adapter) do
  double('AbstractAdapter',
         validated_connection_config: { 'adapter' => 'sqlite3', 'database' => ':memory:' },
         shared_pinned_connection?: false)
end
```

This ensures all existing tests that don't stub `shared_pinned_connection?` continue to see the default "separate pool" behavior.

- [ ] **Step 2: Write the failing tests**

Replace the `context 'pinned model bypass'` block in `spec/unit/patches/connection_handling_spec.rb` (lines 269-313) with:

```ruby
context 'pinned model bypass' do
  before do
    require_relative('../../../lib/apartment/concerns/model')
  end

  context 'when shared_pinned_connection? is false (separate pool)' do
    before do
      allow(mock_adapter).to(receive(:shared_pinned_connection?).and_return(false))
    end

    it 'returns the default pool for a pinned AR::Base subclass when tenant is set' do
      pinned_class = Class.new(ActiveRecord::Base) do
        include Apartment::Model
      end
      stub_const('PinnedBypassModel', pinned_class)
      pinned_class.pin_tenant

      Apartment::Current.tenant = 'acme'
      expect(pinned_class.connection_pool).to(equal(default_pool))
    end

    it 'bypasses for STI subclass of a pinned model' do
      parent = Class.new(ActiveRecord::Base) do
        include Apartment::Model
      end
      stub_const('PinnedParentBypass', parent)
      parent.pin_tenant

      child = Class.new(parent)
      stub_const('PinnedChildBypass', child)

      Apartment::Current.tenant = 'acme'
      expect(child.connection_pool).to(equal(default_pool))
    end
  end

  context 'when shared_pinned_connection? is true (shared pool)' do
    before do
      allow(mock_adapter).to(receive(:shared_pinned_connection?).and_return(true))
    end

    it 'returns the tenant pool for a pinned model (transactional integrity)' do
      pinned_class = Class.new(ActiveRecord::Base) do
        include Apartment::Model
      end
      stub_const('PinnedSharedModel', pinned_class)
      pinned_class.pin_tenant

      Apartment::Current.tenant = 'acme'
      expect(pinned_class.connection_pool).not_to(equal(default_pool))
    end

    it 'returns the tenant pool for STI subclass of a pinned model' do
      parent = Class.new(ActiveRecord::Base) do
        include Apartment::Model
      end
      stub_const('PinnedSharedParent', parent)
      parent.pin_tenant

      child = Class.new(parent)
      stub_const('PinnedSharedChild', child)

      Apartment::Current.tenant = 'acme'
      expect(child.connection_pool).not_to(equal(default_pool))
    end
  end

  it 'does not bypass for ActiveRecord::Base itself' do
    allow(mock_adapter).to(receive(:shared_pinned_connection?).and_return(false))
    Apartment::Current.tenant = 'acme'
    tenant_pool = ActiveRecord::Base.connection_pool
    expect(tenant_pool).not_to(equal(default_pool))
  end

  it 'does not bypass for an unpinned AR::Base subclass' do
    allow(mock_adapter).to(receive(:shared_pinned_connection?).and_return(false))
    unpinned = Class.new(ActiveRecord::Base)
    stub_const('UnpinnedWidget', unpinned)

    Apartment::Current.tenant = 'acme'
    expect(unpinned.connection_pool).not_to(equal(default_pool))
  end
end
```

- [ ] **Step 3: Run tests to verify shared-pool tests fail**

Run: `bundle exec appraisal rails-8.1-sqlite3 rspec spec/unit/patches/connection_handling_spec.rb --format documentation`
Expected: shared-pool pinned model tests fail (pinned models still always bypass)

- [ ] **Step 4: Implement the conditional routing**

In `lib/apartment/patches/connection_handling.rb`, replace lines 20-24:

```ruby
# Skip tenant override for Apartment pinned models.
# Uses explicit registry (not connection_specification_name heuristic)
# because ApplicationRecord subclasses have a different spec name than
# ActiveRecord::Base while sharing the same pool.
return super if self != ActiveRecord::Base && Apartment.pinned_model?(self)
```

With:

```ruby
# Skip tenant override for pinned models only when the adapter requires
# a separate pool (shared_pinned_connection? is false). When shared
# connections are supported (PG schema, MySQL single-server), pinned
# models fall through to the tenant pool lookup, preserving
# transactional integrity between pinned and tenant models.
if self != ActiveRecord::Base && Apartment.pinned_model?(self) &&
   !Apartment.adapter&.shared_pinned_connection?
  return super
end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bundle exec appraisal rails-8.1-sqlite3 rspec spec/unit/patches/connection_handling_spec.rb --format documentation`
Expected: all pass

- [ ] **Step 6: Update `context 'pinned model inside Tenant.each'`**

Replace the `context 'pinned model inside Tenant.each'` block (lines 315-349) with:

```ruby
context 'pinned model inside Tenant.each' do
  before do
    require_relative('../../../lib/apartment/concerns/model')
  end

  context 'when shared_pinned_connection? is false (separate pool)' do
    before do
      allow(mock_adapter).to(receive(:shared_pinned_connection?).and_return(false))
    end

    it 'returns the default pool for a pinned model while iterating tenants' do
      pinned_class = Class.new(ActiveRecord::Base) do
        include Apartment::Model
      end
      stub_const('PinnedInsideEach', pinned_class)
      pinned_class.pin_tenant

      pools_during_each = []
      Apartment::Tenant.each(%w[acme widgets]) do |_tenant|
        pools_during_each << pinned_class.connection_pool
      end

      expect(pools_during_each).to(all(equal(default_pool)))
    end
  end

  context 'when shared_pinned_connection? is true (shared pool)' do
    before do
      allow(mock_adapter).to(receive(:shared_pinned_connection?).and_return(true))
    end

    it 'returns the tenant pool for a pinned model while iterating tenants' do
      pinned_class = Class.new(ActiveRecord::Base) do
        include Apartment::Model
      end
      stub_const('PinnedSharedEach', pinned_class)
      pinned_class.pin_tenant

      pools_during_each = []
      Apartment::Tenant.each(%w[acme widgets]) do |_tenant|
        pools_during_each << pinned_class.connection_pool
      end

      # Pinned model should track tenant pools, not default
      pools_during_each.each do |pool|
        expect(pool).not_to(equal(default_pool))
      end
      expect(pools_during_each[0]).not_to(equal(pools_during_each[1]))
    end
  end

  it 'routes unpinned models to tenant pools while iterating' do
    unpinned = Class.new(ActiveRecord::Base)
    stub_const('UnpinnedInsideEach', unpinned)

    pools_during_each = []
    Apartment::Tenant.each(%w[acme widgets]) do |_tenant|
      pools_during_each << unpinned.connection_pool
    end

    pools_during_each.each do |pool|
      expect(pool).not_to(equal(default_pool))
    end
    expect(pools_during_each[0]).not_to(equal(pools_during_each[1]))
  end
end
```

- [ ] **Step 7: Run tests to verify the Tenant.each tests pass**

Run: `bundle exec appraisal rails-8.1-sqlite3 rspec spec/unit/patches/connection_handling_spec.rb --format documentation`
Expected: all pass

- [ ] **Step 8: Commit**

```bash
git add lib/apartment/patches/connection_handling.rb spec/unit/patches/connection_handling_spec.rb
git commit -m "Conditionally route pinned models through tenant pool

When shared_pinned_connection? is true, pinned models fall through
to the tenant pool lookup instead of short-circuiting to the default
pool. Preserves transactional integrity between pinned and tenant
model writes.

Co-Authored-By: henkesn <14108170+henkesn@users.noreply.github.com>
Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: Update integration tests for dual-path behavior

**Files:**
- Modify: `spec/integration/v4/excluded_models_spec.rb`

- [ ] **Step 1: Update existing integration tests**

In `spec/integration/v4/excluded_models_spec.rb`, replace the test at line 69:

```ruby
it 'pin_tenant establishes a dedicated connection for the model' do
  expect(GlobalSetting.connection_specification_name).not_to(eq(ActiveRecord::Base.connection_specification_name))
end
```

With two context-separated tests:

```ruby
context 'pinned model connection routing' do
  it 'shares the tenant connection when shared_pinned_connection? is true' do
    if Apartment.adapter.shared_pinned_connection?
      expect(GlobalSetting.connection_specification_name).to(eq(ActiveRecord::Base.connection_specification_name))
    else
      skip 'adapter does not support shared pinned connections'
    end
  end

  it 'uses a separate connection when shared_pinned_connection? is false' do
    unless Apartment.adapter.shared_pinned_connection?
      expect(GlobalSetting.connection_specification_name).not_to(eq(ActiveRecord::Base.connection_specification_name))
    else
      skip 'adapter supports shared pinned connections'
    end
  end
end
```

Replace the idempotency test at line 73:

```ruby
it 'pin_tenant is idempotent' do
  expect { Apartment.adapter.process_pinned_models }.not_to(raise_error)
end
```

With:

```ruby
it 'pin_tenant is idempotent' do
  expect { Apartment.adapter.process_pinned_models }.not_to(raise_error)
  unless Apartment.adapter.shared_pinned_connection?
    expect(GlobalSetting.connection_specification_name).not_to(eq(ActiveRecord::Base.connection_specification_name))
  end
end
```

- [ ] **Step 2: Add transactional integrity tests**

Add after the `context 'ApplicationRecord topology'` block:

```ruby
context 'transactional integrity (shared connection path)' do
  it 'rolls back both pinned and tenant model writes on transaction rollback' do
    skip 'requires shared_pinned_connection?' unless Apartment.adapter.shared_pinned_connection?

    Apartment::Tenant.switch('tenant_a') do
      ActiveRecord::Base.transaction do
        Widget.create!(name: 'will_be_rolled_back')
        GlobalSetting.create!(key: 'will_be_rolled_back', value: 'yes')
        raise ActiveRecord::Rollback
      end

      expect(Widget.count).to(eq(0))
      expect(GlobalSetting.where(key: 'will_be_rolled_back').count).to(eq(0))
    end
  end

  it 'commits both pinned and tenant model writes on successful transaction' do
    skip 'requires shared_pinned_connection?' unless Apartment.adapter.shared_pinned_connection?

    Apartment::Tenant.switch('tenant_a') do
      ActiveRecord::Base.transaction do
        Widget.create!(name: 'committed')
        GlobalSetting.create!(key: 'committed', value: 'yes')
      end

      expect(Widget.find_by(name: 'committed')).to(be_present)
      expect(GlobalSetting.find_by(key: 'committed')).to(be_present)
    end
  end
end
```

- [ ] **Step 3: Run integration tests**

Run: `bundle exec appraisal rails-8.1-sqlite3 rspec spec/integration/v4/excluded_models_spec.rb --format documentation`
Expected: all pass (some skipped based on adapter capability)

Run (if PG available): `DATABASE_ENGINE=postgresql bundle exec appraisal rails-8.1-postgresql rspec spec/integration/v4/excluded_models_spec.rb --format documentation`
Expected: all pass including transactional integrity tests

- [ ] **Step 4: Commit**

```bash
git add spec/integration/v4/excluded_models_spec.rb
git commit -m "Update integration tests for dual-path pinned model behavior

Separate context blocks for shared vs separate pool. Add transactional
integrity tests: rollback rolls back both pinned and tenant writes
when shared connections are supported.

Co-Authored-By: henkesn <14108170+henkesn@users.noreply.github.com>
Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 9: Update upgrade guide and docstrings

**Files:**
- Modify: `docs/upgrading-to-v4.md:119-120`
- Modify: `lib/apartment/adapters/abstract_adapter.rb` (process_pinned_models docstring)

- [ ] **Step 1: Add Pinned Model Connections section to upgrade guide**

In `docs/upgrading-to-v4.md`, insert after line 119 (after "The Railtie emits a boot-time warning if `isolation_level` is `:thread`.") and before "Key config options for pool tuning:":

```markdown
### Pinned Model Connections

In v3, pinned (excluded) models always received their own connection pool via `establish_connection`. This meant they never participated in the same database transaction as tenant-scoped models.

v4 fixes this for strategies where the database engine supports cross-schema/database queries on a single connection:

| Strategy | Pinned model connection in v4 |
|---|---|
| PostgreSQL schema | Shares tenant connection (qualified table name) |
| MySQL / Trilogy single-server | Shares tenant connection (qualified table name) |
| PostgreSQL database-per-tenant | Separate pool (unchanged from v3) |
| SQLite | Separate pool (unchanged from v3) |

For PG schema and MySQL/Trilogy, pinned models now use the tenant's connection pool with a fully qualified table name (e.g. `public.delayed_jobs`). This means pinned model writes participate in the same transaction as tenant DML.

**Action required if you relied on the old behavior:**

If your code assumes that pinned model writes survive a tenant transaction rollback (e.g., enqueuing a job and deliberately rolling back tenant data), set `force_separate_pinned_pool: true` in your Apartment config:

```ruby
Apartment.configure do |config|
  config.force_separate_pinned_pool = true
  # ...
end
```

`after_commit` callbacks still fire as before. The difference is that pinned model writes are now inside the tenant transaction, so an `ActiveRecord::Rollback` that aborts the transaction will also roll back pinned model writes. Apps using `after_commit` for job enqueueing are unaffected.

For PG database-per-tenant, SQLite, and multi-server setups, pinned model behavior is unchanged from v3.
```

- [ ] **Step 2: Update the process_pinned_models docstring**

In `lib/apartment/adapters/abstract_adapter.rb`, replace the docstring above `process_pinned_models` (line 99):

```ruby
# Process all pinned models — establish separate connections pinned to default tenant.
```

With:

```ruby
# Process all pinned models. When shared_pinned_connection? is true, qualifies
# table names for shared pool routing. Otherwise, establishes separate connections.
```

- [ ] **Step 3: Run rubocop on changed files**

Run: `bundle exec rubocop lib/apartment/adapters/abstract_adapter.rb lib/apartment/patches/connection_handling.rb lib/apartment/config.rb lib/apartment.rb`
Expected: no offenses

- [ ] **Step 4: Run full unit suite**

Run: `bundle exec rspec spec/unit/ --format progress`
Expected: all pass

- [ ] **Step 5: Commit**

```bash
git add docs/upgrading-to-v4.md lib/apartment/adapters/abstract_adapter.rb
git commit -m "Update upgrade guide and docstrings for shared pinned connections

Add Pinned Model Connections section to upgrading-to-v4.md with
adapter matrix, force_separate_pinned_pool escape hatch, and
after_commit nuance. Update process_pinned_models docstring.

Co-Authored-By: henkesn <14108170+henkesn@users.noreply.github.com>
Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 10: Final verification across all Rails versions

**Files:** None (verification only)

- [ ] **Step 1: Run unit tests across all Rails versions**

Run: `bundle exec appraisal rspec spec/unit/ --format progress`
Expected: all pass across all Rails versions

- [ ] **Step 2: Run integration tests (SQLite)**

Run: `bundle exec appraisal rails-8.1-sqlite3 rspec spec/integration/v4/ --format documentation`
Expected: all pass (shared connection tests skipped for SQLite)

- [ ] **Step 3: Run integration tests (PostgreSQL, if available)**

Run: `DATABASE_ENGINE=postgresql bundle exec appraisal rails-8.1-postgresql rspec spec/integration/v4/ --format documentation`
Expected: all pass including shared connection and transactional integrity tests

- [ ] **Step 4: Run integration tests (MySQL, if available)**

Run: `DATABASE_ENGINE=mysql bundle exec appraisal rails-8.1-mysql2 rspec spec/integration/v4/ --format documentation`
Expected: all pass including shared connection tests

- [ ] **Step 5: Run rubocop on all changed files**

Run: `bundle exec rubocop lib/apartment/adapters/abstract_adapter.rb lib/apartment/adapters/postgresql_schema_adapter.rb lib/apartment/adapters/mysql2_adapter.rb lib/apartment/patches/connection_handling.rb lib/apartment/config.rb lib/apartment.rb spec/unit/adapters/abstract_adapter_spec.rb spec/unit/adapters/postgresql_schema_adapter_spec.rb spec/unit/adapters/mysql2_adapter_spec.rb spec/unit/patches/connection_handling_spec.rb spec/unit/config_spec.rb spec/integration/v4/excluded_models_spec.rb`
Expected: no offenses
