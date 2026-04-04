# Phase 7.1: Excluded Models Fix + Apartment::Model Concern — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix excluded model isolation for database-per-tenant strategies and introduce `Apartment::Model` with `pin_tenant` as the primary API, deprecating `config.excluded_models`.

**Architecture:** Explicit model-level `pin_tenant` declaration registers models in `Apartment.pinned_models` (a `Concurrent::Set`). `ConnectionHandling#connection_pool` checks this registry via `Apartment.pinned_model?` (ancestor walk) to skip tenant pool routing for pinned models. `process_excluded_models` is renamed to `process_pinned_models` and hardened with table existence validation. `config.excluded_models` is preserved as a deprecated shim.

**Tech Stack:** Ruby, ActiveRecord, ActiveSupport::Concern, Concurrent::Set, RSpec

**Design spec:** `docs/designs/v4-phase7.1-excluded-models-pin-tenant.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `lib/apartment/concerns/model.rb` | Create | `Apartment::Model` concern with `pin_tenant`, `apartment_pinned?` |
| `lib/apartment.rb` | Modify | `pinned_models`, `register_pinned_model`, `pinned_model?`, `activated?`, `process_pinned_model`, `clear_config` reset |
| `lib/apartment/patches/connection_handling.rb` | Modify | Early return for pinned models |
| `lib/apartment/adapters/abstract_adapter.rb` | Modify | `process_pinned_models`, `process_pinned_model`, deprecation alias |
| `lib/apartment/tenant.rb` | Modify | `init` calls `process_pinned_models` |
| `lib/apartment/railtie.rb` | Modify | Set `@activated` in `activate!` |
| `lib/apartment/config.rb` | Modify | Deprecation warning on `excluded_models=` |
| `spec/unit/concerns/model_spec.rb` | Create | Unit tests for `Apartment::Model` |
| `spec/unit/adapters/abstract_adapter_spec.rb` | Modify | Update `process_excluded_models` tests |
| `spec/integration/v4/excluded_models_spec.rb` | Modify | Remove pending guards, add new specs |

---

### Task 1: `Apartment::Model` Concern + Unit Tests

**Files:**
- Create: `lib/apartment/concerns/model.rb`
- Create: `spec/unit/concerns/model_spec.rb`

- [ ] **Step 1: Write the failing test for `pin_tenant` registration**

Create `spec/unit/concerns/model_spec.rb`:

```ruby
# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../lib/apartment/concerns/model'

RSpec.describe(Apartment::Model) do
  before do
    Apartment.configure do |c|
      c.tenant_strategy = :schema
      c.tenants_provider = -> { [] }
      c.default_tenant = 'public'
    end
  end

  after do
    Apartment.clear_config
  end

  describe '.pin_tenant' do
    it 'registers the model in Apartment.pinned_models' do
      klass = Class.new(ActiveRecord::Base) do
        include Apartment::Model
      end
      stub_const('PinnedTestModel', klass)

      klass.pin_tenant

      expect(Apartment.pinned_models).to(include(PinnedTestModel))
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/unit/concerns/model_spec.rb -v`
Expected: FAIL — `Apartment::Model` not defined or `Apartment.pinned_models` not defined.

- [ ] **Step 3: Implement `Apartment::Model` concern**

Create `lib/apartment/concerns/model.rb`:

```ruby
# frozen_string_literal: true

require 'active_support/concern'

module Apartment
  module Model
    extend ActiveSupport::Concern

    class_methods do
      # Declare this model as pinned to the default tenant.
      # Pinned models bypass tenant switching in ConnectionHandling —
      # their connection always targets the default tenant's database/schema.
      #
      # Safe to call before or after Apartment.activate!.
      # Idempotent: no-op if this class (or a parent) is already pinned.
      def pin_tenant
        return if apartment_pinned?

        Apartment.register_pinned_model(self)
        @apartment_pinned = true

        # If Apartment is already activated, process immediately (Zeitwerk autoload path).
        # Otherwise, activate! will process all registered models.
        Apartment.process_pinned_model(self) if Apartment.activated?
      end

      def apartment_pinned?
        return true if @apartment_pinned == true
        return false unless superclass.respond_to?(:apartment_pinned?)

        superclass.apartment_pinned?
      end
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/unit/concerns/model_spec.rb -v`
Expected: Fails because `Apartment.pinned_models` doesn't exist yet. That's expected — Task 2 adds it.

- [ ] **Step 5: Write remaining unit tests for `pin_tenant`**

Add to `spec/unit/concerns/model_spec.rb`:

```ruby
  describe '.pin_tenant' do
    # ... existing test ...

    it 'is idempotent — second call is a no-op' do
      klass = Class.new(ActiveRecord::Base) do
        include Apartment::Model
      end
      stub_const('IdempotentModel', klass)

      klass.pin_tenant
      klass.pin_tenant

      expect(Apartment.pinned_models.count { |m| m == IdempotentModel }).to(eq(1))
    end

    it 'processes immediately when Apartment is already activated' do
      expect(Apartment).to(receive(:activated?).and_return(true))
      expect(Apartment).to(receive(:process_pinned_model))

      klass = Class.new(ActiveRecord::Base) do
        include Apartment::Model
      end
      stub_const('LateLoadedModel', klass)

      klass.pin_tenant
    end

    it 'defers processing when Apartment is not yet activated' do
      expect(Apartment).to(receive(:activated?).and_return(false))
      expect(Apartment).not_to(receive(:process_pinned_model))

      klass = Class.new(ActiveRecord::Base) do
        include Apartment::Model
      end
      stub_const('EarlyModel', klass)

      klass.pin_tenant
    end
  end

  describe '.apartment_pinned?' do
    it 'returns false for unpinned models' do
      klass = Class.new(ActiveRecord::Base) do
        include Apartment::Model
      end

      expect(klass.apartment_pinned?).to(be(false))
    end

    it 'returns true after pin_tenant' do
      klass = Class.new(ActiveRecord::Base) do
        include Apartment::Model
      end
      stub_const('PinnedCheck', klass)

      klass.pin_tenant
      expect(klass.apartment_pinned?).to(be(true))
    end

    it 'returns true for subclass of pinned model (STI)' do
      parent = Class.new(ActiveRecord::Base) do
        include Apartment::Model
      end
      stub_const('PinnedParent', parent)
      parent.pin_tenant

      child = Class.new(parent)
      stub_const('PinnedChild', child)

      expect(child.apartment_pinned?).to(be(true))
    end

    it 'returns false for classes without the concern' do
      klass = Class.new(ActiveRecord::Base)

      expect(klass.respond_to?(:apartment_pinned?)).to(be(false))
    end
  end
```

- [ ] **Step 6: Commit**

```bash
git add lib/apartment/concerns/model.rb spec/unit/concerns/model_spec.rb
git commit -m "feat: add Apartment::Model concern with pin_tenant

Introduces model-level declaration for pinning models to the default
tenant. Replaces centralized config.excluded_models with a Rails-
idiomatic include + DSL pattern."
```

---

### Task 2: `Apartment` Module Registry Methods

**Files:**
- Modify: `lib/apartment.rb:31-81` (class << self block)

- [ ] **Step 1: Write the failing test for `pinned_models` and `pinned_model?`**

These are tested indirectly through the concern tests from Task 1. Verify the Task 1 tests now pass after adding the module methods.

- [ ] **Step 2: Add registry methods to `lib/apartment.rb`**

Add inside `class << self`, after the `adapter` method (line 40) and before `configure`:

```ruby
    # Registry of models that declared pin_tenant.
    # Uses Concurrent::Set for thread safety (Zeitwerk autoload in threaded servers).
    def pinned_models
      @pinned_models ||= Concurrent::Set.new
    end

    def register_pinned_model(klass)
      pinned_models.add(klass)
    end

    # Check if a class (or any of its ancestors) is a pinned model.
    # Used by ConnectionHandling to skip tenant pool routing.
    def pinned_model?(klass)
      klass.ancestors.any? { |a| a.is_a?(Class) && pinned_models.include?(a) }
    end

    def activated?
      @activated == true
    end

    def process_pinned_model(klass)
      adapter&.process_pinned_model(klass)
    end
```

Add `require 'concurrent'` at the top of the file (after `require 'active_support/current_attributes'`). Note: `concurrent-ruby` is already a transitive dependency via ActiveSupport.

- [ ] **Step 3: Update `clear_config` to reset pinned state**

In `lib/apartment.rb`, update `clear_config`:

```ruby
    def clear_config
      teardown_old_state
      @config = nil
      @pool_manager = nil
      @pool_reaper = nil
      @pinned_models = nil
      @activated = false
    end
```

- [ ] **Step 4: Update `activate!` to set `@activated`**

In `lib/apartment.rb`, update `activate!`:

```ruby
    def activate!
      require_relative('apartment/patches/connection_handling')
      ActiveRecord::Base.singleton_class.prepend(Patches::ConnectionHandling)
      @activated = true
    end
```

- [ ] **Step 5: Run concern tests to verify they pass**

Run: `bundle exec rspec spec/unit/concerns/model_spec.rb -v`
Expected: All pass.

- [ ] **Step 6: Run full unit suite to check for regressions**

Run: `bundle exec rspec spec/unit/ -v`
Expected: All existing tests pass. `clear_config` resets pinned state.

- [ ] **Step 7: Commit**

```bash
git add lib/apartment.rb
git commit -m "feat: add pinned_models registry to Apartment module

Concurrent::Set registry for pin_tenant models. pinned_model? walks
ancestors for STI support. clear_config resets pinned state.
activate! sets @activated flag for deferred/immediate processing."
```

---

### Task 3: `ConnectionHandling` Pinned Model Guard

**Files:**
- Modify: `lib/apartment/patches/connection_handling.rb:16-19`

- [ ] **Step 1: Write the failing unit test**

The existing `spec/apartment/patches/connection_handling_spec.rb` or integration tests should cover this. First, check if a unit spec exists:

Run: `ls spec/unit/patches/ 2>/dev/null || ls spec/apartment/patches/ 2>/dev/null || echo "no existing spec"`

If no unit spec exists, the integration tests in Task 8 will cover this. For now, write a focused unit test in a new file `spec/unit/patches/connection_handling_spec.rb`:

```ruby
# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../lib/apartment/patches/connection_handling'
require_relative '../../../lib/apartment/concerns/model'

RSpec.describe(Apartment::Patches::ConnectionHandling) do
  before do
    Apartment.configure do |c|
      c.tenant_strategy = :schema
      c.tenants_provider = -> { [] }
      c.default_tenant = 'public'
    end
    Apartment.activate!
  end

  after do
    Apartment.clear_config
    Apartment::Current.reset
  end

  describe 'pinned_model? registry check' do
    it 'returns true for a pinned model' do
      pinned_class = Class.new(ActiveRecord::Base) do
        include Apartment::Model
      end
      stub_const('PinnedGlobal', pinned_class)
      pinned_class.pin_tenant

      expect(Apartment.pinned_model?(PinnedGlobal)).to(be(true))
    end

    it 'returns true for STI subclass of a pinned model' do
      parent = Class.new(ActiveRecord::Base) do
        include Apartment::Model
      end
      stub_const('PinnedParentModel', parent)
      parent.pin_tenant

      child = Class.new(parent)
      stub_const('PinnedChildModel', child)

      expect(Apartment.pinned_model?(PinnedChildModel)).to(be(true))
    end

    it 'returns false for normal tenant models' do
      tenant_class = Class.new(ActiveRecord::Base)
      stub_const('TenantWidget', tenant_class)

      expect(Apartment.pinned_model?(TenantWidget)).to(be(false))
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails or baseline**

Run: `bundle exec rspec spec/unit/patches/connection_handling_spec.rb -v`

- [ ] **Step 3: Add pinned model guard to `ConnectionHandling`**

In `lib/apartment/patches/connection_handling.rb`, add after line 18 (`return super unless Apartment.pool_manager`):

```ruby
        # Skip tenant override for Apartment pinned models.
        # Uses explicit registry (not connection_specification_name heuristic)
        # because ApplicationRecord subclasses have a different spec name than
        # ActiveRecord::Base while sharing the same pool.
        return super if self != ActiveRecord::Base && Apartment.pinned_model?(self)
```

The full method now reads (lines 12-20):

```ruby
      def connection_pool
        tenant = Apartment::Current.tenant
        cfg = Apartment.config

        return super if tenant.nil? || cfg.nil?
        return super if tenant.to_s == cfg.default_tenant.to_s
        return super unless Apartment.pool_manager

        # Skip tenant override for Apartment pinned models.
        return super if self != ActiveRecord::Base && Apartment.pinned_model?(self)

        role = ActiveRecord::Base.current_role
        # ... rest unchanged
```

- [ ] **Step 4: Run tests**

Run: `bundle exec rspec spec/unit/patches/connection_handling_spec.rb spec/unit/ -v`
Expected: All pass.

- [ ] **Step 5: Commit**

```bash
git add lib/apartment/patches/connection_handling.rb spec/unit/patches/connection_handling_spec.rb
git commit -m "feat: ConnectionHandling skips tenant routing for pinned models

Adds explicit registry check via Apartment.pinned_model? after the
existing nil/default/pool_manager guards. Uses ancestor walk instead
of connection_specification_name to avoid ApplicationRecord false
positives."
```

---

### Task 4: `process_pinned_models` in AbstractAdapter

**Files:**
- Modify: `lib/apartment/adapters/abstract_adapter.rb:99-116`
- Modify: `spec/unit/adapters/abstract_adapter_spec.rb:322-406`

- [ ] **Step 1: Write the failing test for `process_pinned_models`**

Add to `spec/unit/adapters/abstract_adapter_spec.rb`, after the existing `#process_excluded_models` block:

```ruby
  describe '#process_pinned_models' do
    it 'establishes connections for each pinned model' do
      model_class = Class.new(ActiveRecord::Base) do
        include Apartment::Model
      end
      stub_const('PinnedSetting', model_class)
      allow(model_class).to(receive(:table_name).and_return('pinned_settings'))
      allow(model_class).to(receive(:table_name=))

      PinnedSetting.pin_tenant

      expected_config = { 'adapter' => 'postgresql', 'database' => 'public' }
      expect(model_class).to(receive(:establish_connection)) do |arg|
        expect(arg).to(eq(expected_config))
      end

      adapter.process_pinned_models
    end

    it 'skips models already processed (idempotent)' do
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

      # Second call skips — @apartment_connection_established is set
      expect(model_class).not_to(receive(:establish_connection))
      adapter.process_pinned_models
    end

    it 'prefixes table name with default schema for schema strategy' do
      model_class = Class.new(ActiveRecord::Base) do
        include Apartment::Model
      end
      stub_const('SchemaPinned', model_class)
      allow(model_class).to(receive(:establish_connection))
      allow(model_class).to(receive(:table_name).and_return('schema_pinned'))

      SchemaPinned.pin_tenant

      expect(model_class).to(receive(:table_name=).with('public.schema_pinned'))
      adapter.process_pinned_models
    end

    it 'does nothing when no models are pinned' do
      expect { adapter.process_pinned_models }.not_to(raise_error)
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/unit/adapters/abstract_adapter_spec.rb -e 'process_pinned_models' -v`
Expected: FAIL — `process_pinned_models` not defined.

- [ ] **Step 3: Implement `process_pinned_models` and `process_pinned_model`**

Replace the `process_excluded_models` method in `lib/apartment/adapters/abstract_adapter.rb` (lines 99-116):

```ruby
      # Process all pinned models — establish separate connections pinned to default tenant.
      def process_pinned_models
        return if Apartment.pinned_models.empty?

        Apartment.pinned_models.each do |klass|
          process_pinned_model(klass)
        end
      end

      # Process a single pinned model. Called by process_pinned_models (batch)
      # and by Apartment::Model.pin_tenant (when activated? is true).
      def process_pinned_model(klass)
        # Idempotent: skip if already processed. Uses a class-level flag rather
        # than connection_specification_name comparison — the spec name differs
        # from ActiveRecord::Base for ApplicationRecord subclasses even before
        # establish_connection, so it's not a reliable "already processed" signal.
        return if klass.instance_variable_get(:@apartment_connection_established)

        default_config = resolve_connection_config(Apartment.config.default_tenant)
        klass.establish_connection(default_config)
        klass.instance_variable_set(:@apartment_connection_established, true)

        if Apartment.config.tenant_strategy == :schema
          table = klass.table_name.split('.').last
          klass.table_name = "#{default_tenant}.#{table}"
        end
      end

      # Deprecated: use process_pinned_models instead.
      # Models registered via config.excluded_models are resolved and registered
      # as pinned models during activate! (see Railtie / Tenant.init).
      def process_excluded_models
        warn '[Apartment] DEPRECATION: process_excluded_models is deprecated. ' \
             'Use Apartment::Model with pin_tenant instead.'
        process_pinned_models
      end
```

Also remove the now-unused `resolve_excluded_model` private method (lines 181-185) — its functionality moves to the `excluded_models` shim in Task 5.

- [ ] **Step 4: Run tests**

Run: `bundle exec rspec spec/unit/adapters/abstract_adapter_spec.rb -v`
Expected: New `process_pinned_models` tests pass. Existing `process_excluded_models` tests may fail — they reference the old implementation. Update them in step 5.

- [ ] **Step 5: Update existing `process_excluded_models` tests**

The existing tests in `#process_excluded_models` (lines 322-406) should continue to work via the deprecated `config.excluded_models` shim (Task 5 wires that). For now, update the describe block to note the deprecation and verify the shim emits a warning:

Replace the existing `describe '#process_excluded_models'` block with:

```ruby
  describe '#process_excluded_models (deprecated)' do
    it 'emits a deprecation warning' do
      reconfigure(excluded_models: [])
      expect { adapter.process_excluded_models }
        .to(output(/DEPRECATION.*process_excluded_models/).to_stderr_from_all_processes)
    end

    it 'delegates to process_pinned_models' do
      reconfigure(excluded_models: [])
      expect(adapter).to(receive(:process_pinned_models))
      adapter.process_excluded_models
    end
  end
```

- [ ] **Step 6: Run full unit suite**

Run: `bundle exec rspec spec/unit/ -v`
Expected: All pass.

- [ ] **Step 7: Commit**

```bash
git add lib/apartment/adapters/abstract_adapter.rb spec/unit/adapters/abstract_adapter_spec.rb
git commit -m "feat: replace process_excluded_models with process_pinned_models

Iterates Apartment.pinned_models registry instead of config string list.
Idempotent: skips models with existing connections. Deprecation alias
for process_excluded_models."
```

---

### Task 5: `config.excluded_models` Deprecation Shim + `Tenant.init` Update

**Files:**
- Modify: `lib/apartment/config.rb:17`
- Modify: `lib/apartment/tenant.rb:41-42`
- Modify: `lib/apartment/railtie.rb:20-21`

- [ ] **Step 1: Write the failing test for the deprecation warning**

Add to `spec/unit/adapters/abstract_adapter_spec.rb` or a new config spec:

```ruby
  describe 'config.excluded_models deprecation shim' do
    it 'resolves excluded model strings and registers them as pinned' do
      model_class = Class.new(ActiveRecord::Base)
      stub_const('DeprecatedExcluded', model_class)
      allow(model_class).to(receive(:table_name).and_return('deprecated_excluded'))
      allow(model_class).to(receive(:table_name=))
      allow(model_class).to(receive(:establish_connection))
      allow(model_class).to(receive(:connection_specification_name).and_return('ActiveRecord::Base'))

      reconfigure(excluded_models: ['DeprecatedExcluded'])

      Apartment::Tenant.init

      expect(Apartment.pinned_models).to(include(DeprecatedExcluded))
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/unit/adapters/abstract_adapter_spec.rb -e 'deprecation shim' -v`
Expected: FAIL — `Tenant.init` still calls old `process_excluded_models`.

- [ ] **Step 3: Update `Tenant.init` to resolve excluded_models and call `process_pinned_models`**

In `lib/apartment/tenant.rb`, replace `init`:

```ruby
      # Initialize: resolve excluded_models shim, then process pinned models.
      def init
        resolve_excluded_models_shim
        adapter.process_pinned_models
      end

      private

      def adapter
        Apartment.adapter or
          raise(ConfigurationError, 'Apartment adapter not configured. Call Apartment.configure first.')
      end

      # Resolve config.excluded_models strings into pinned model registrations.
      # This is the deprecated compatibility path — new code should use
      # `include Apartment::Model` + `pin_tenant` in each model.
      def resolve_excluded_models_shim
        return if Apartment.config.excluded_models.empty?

        Apartment.config.excluded_models.each do |model_name|
          klass = model_name.constantize
          next if Apartment.pinned_models.include?(klass)

          if klass.respond_to?(:apartment_pinned?) && klass.apartment_pinned?
            warn "[Apartment] WARNING: #{model_name} is in config.excluded_models " \
                 'AND declares pin_tenant. Remove it from excluded_models.'
            next
          end

          Apartment.register_pinned_model(klass)
        rescue NameError => e
          raise(Apartment::ConfigurationError,
                "Excluded model '#{model_name}' could not be resolved: #{e.message}")
        end
      end
```

- [ ] **Step 4: Add deprecation warning on `excluded_models=` setter**

In `lib/apartment/config.rb`, replace the `attr_accessor :excluded_models` with a custom setter. Change line 17:

Remove `excluded_models` from the `attr_accessor` line and add:

```ruby
    attr_reader :excluded_models
```

Add after `initialize`:

```ruby
    def excluded_models=(list)
      unless list.empty?
        warn '[Apartment] DEPRECATION: config.excluded_models is deprecated and will be ' \
             "removed in v5. Use `include Apartment::Model` and `pin_tenant` in each model instead.\n" \
             'For third-party gem models, use config.excluded_models as a transitional escape hatch.'
      end
      @excluded_models = list
    end
```

- [ ] **Step 5: Run tests**

Run: `bundle exec rspec spec/unit/ -v`
Expected: All pass. Existing tests that set `excluded_models: []` won't trigger the warning (empty list guard).

- [ ] **Step 6: Commit**

```bash
git add lib/apartment/tenant.rb lib/apartment/config.rb
git commit -m "feat: deprecation shim for config.excluded_models

Tenant.init resolves excluded_models strings into pinned model
registrations before calling process_pinned_models. Deprecation
warning on non-empty excluded_models= setter. Duplicate detection
warns if model uses both paths."
```

---

### Task 6: Railtie `activated?` Flag

**Files:**
- Modify: `lib/apartment/railtie.rb:19-22`

- [ ] **Step 1: Verify `activated?` is already set in `activate!`**

Task 2 added `@activated = true` to `Apartment.activate!`. The Railtie calls `Apartment.activate!` then `Apartment::Tenant.init`. This ordering is correct — `activate!` sets the flag, then `init` processes pinned models. No Railtie changes needed beyond what Task 2 already did.

- [ ] **Step 2: Verify boot order in Railtie**

Read `lib/apartment/railtie.rb` and confirm the call sequence is:
1. `Apartment.activate!` (prepends ConnectionHandling, sets `@activated = true`)
2. `Apartment::Tenant.init` (resolves excluded_models shim, calls `process_pinned_models`)

This is already the correct order in the existing Railtie (lines 20-21).

- [ ] **Step 3: Run unit tests**

Run: `bundle exec rspec spec/unit/ -v`
Expected: All pass.

- [ ] **Step 4: Commit (only if Railtie needed changes)**

If no changes were needed, skip this commit.

---

### Task 7: Integration Tests — Core Pinned Model Specs

**Files:**
- Modify: `spec/integration/v4/excluded_models_spec.rb`

- [ ] **Step 1: Update existing spec to use `pin_tenant` instead of `config.excluded_models`**

Rewrite `spec/integration/v4/excluded_models_spec.rb`. The key changes:
- `GlobalSetting` uses `include Apartment::Model` + `pin_tenant` instead of `config.excluded_models`
- Remove all `pending` guards for non-PG engines
- Add `ApplicationRecord` abstract class for realistic topology
- Keep `Widget` as a normal tenant model

```ruby
# frozen_string_literal: true

require 'spec_helper'
require_relative 'support'
require 'apartment/concerns/model'

RSpec.describe('v4 Pinned models integration (Apartment::Model)', :integration,
               skip: (V4_INTEGRATION_AVAILABLE ? false : 'requires ActiveRecord + database gem')) do
  include V4IntegrationHelper

  let(:tmp_dir) { Dir.mktmpdir('apartment_pinned') }
  let(:created_tenants) { [] }

  before do
    V4IntegrationHelper.ensure_test_database! unless V4IntegrationHelper.sqlite?
    config = V4IntegrationHelper.establish_default_connection!(tmp_dir: tmp_dir)

    # Create tables in default database
    ActiveRecord::Base.connection.create_table(:global_settings, force: true) do |t|
      t.string(:key)
      t.string(:value)
    end
    V4IntegrationHelper.create_test_table!

    # Simulate ApplicationRecord for realistic topology
    stub_const('ApplicationRecord', Class.new(ActiveRecord::Base) {
      self.abstract_class = true
    })

    stub_const('GlobalSetting', Class.new(ApplicationRecord) {
      self.table_name = 'global_settings'
      include Apartment::Model
      pin_tenant
    })

    stub_const('Widget', Class.new(ApplicationRecord) {
      self.table_name = 'widgets'
    })

    Apartment.configure do |c|
      c.tenant_strategy = V4IntegrationHelper.tenant_strategy
      c.tenants_provider = -> { %w[tenant_a] }
      c.default_tenant = V4IntegrationHelper.default_tenant
      c.check_pending_migrations = false
    end

    Apartment.adapter = V4IntegrationHelper.build_adapter(config)
    Apartment.activate!
    Apartment.adapter.process_pinned_models

    Apartment.adapter.create('tenant_a')
    created_tenants << 'tenant_a'
    Apartment::Tenant.switch('tenant_a') do
      V4IntegrationHelper.create_test_table!('widgets', connection: ActiveRecord::Base.connection)
    end
  end

  after do
    V4IntegrationHelper.cleanup_tenants!(created_tenants, Apartment.adapter)
    Apartment.clear_config
    Apartment::Current.reset
    if V4IntegrationHelper.sqlite?
      ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
      FileUtils.rm_rf(tmp_dir)
    end
  end

  it 'pin_tenant establishes a dedicated connection for the model' do
    expect(GlobalSetting.connection_specification_name).not_to(eq(ActiveRecord::Base.connection_specification_name))
  end

  it 'pin_tenant is idempotent' do
    expect { Apartment.adapter.process_pinned_models }.not_to(raise_error)
    expect(GlobalSetting.connection_specification_name).not_to(eq(ActiveRecord::Base.connection_specification_name))
  end

  it 'pinned model queries always target the default database' do
    GlobalSetting.create!(key: 'site_name', value: 'TestSite')

    Apartment::Tenant.switch('tenant_a') do
      expect(GlobalSetting.count).to(eq(1))
      expect(GlobalSetting.first.key).to(eq('site_name'))
      expect(Widget.count).to(eq(0))
    end
  end

  it 'pinned model data persists across tenant switches' do
    GlobalSetting.create!(key: 'version', value: '1.0')

    Apartment::Tenant.switch('tenant_a') do
      expect(GlobalSetting.find_by(key: 'version').value).to(eq('1.0'))
    end

    expect(GlobalSetting.count).to(eq(1))
  end

  it 'pinned model writes inside a tenant block land in the default database' do
    Apartment::Tenant.switch('tenant_a') do
      GlobalSetting.create!(key: 'inside_tenant', value: 'yes')
    end

    expect(GlobalSetting.find_by(key: 'inside_tenant')).to(be_present)
  end

  it 'tenant model (Widget) still routes through tenant pool during switch' do
    Apartment::Tenant.switch('tenant_a') do
      Widget.create!(name: 'in_tenant')
      expect(Widget.count).to(eq(1))
    end

    # Back in default — tenant widget not visible (different database/schema)
    # For PG schema, public.widgets might exist; for DB-per-tenant, no widgets table in default
    if V4IntegrationHelper.postgresql?
      # Schema strategy: widgets table exists in public, should be empty
      expect(Widget.count).to(eq(0))
    end
  end

  context 'ApplicationRecord topology' do
    it 'normal models inheriting from ApplicationRecord get tenant routing' do
      Apartment::Tenant.switch('tenant_a') do
        Widget.create!(name: 'routed_correctly')
        expect(Widget.count).to(eq(1))
      end
    end
  end

  context 'STI subclass of pinned model' do
    before do
      stub_const('AdminSetting', Class.new(GlobalSetting))
    end

    it 'inherits pinned behavior' do
      AdminSetting.create!(key: 'admin_only', value: 'true')

      Apartment::Tenant.switch('tenant_a') do
        expect(AdminSetting.find_by(key: 'admin_only').value).to(eq('true'))
      end
    end
  end

  context 'config.excluded_models shim' do
    it 'still works via deprecated path' do
      # Re-setup with config.excluded_models instead of pin_tenant
      stub_const('LegacySetting', Class.new(ApplicationRecord) {
        self.table_name = 'global_settings'
      })

      Apartment.clear_config
      config = V4IntegrationHelper.establish_default_connection!(tmp_dir: tmp_dir)

      Apartment.configure do |c|
        c.tenant_strategy = V4IntegrationHelper.tenant_strategy
        c.tenants_provider = -> { %w[tenant_a] }
        c.default_tenant = V4IntegrationHelper.default_tenant
        c.excluded_models = ['LegacySetting']
        c.check_pending_migrations = false
      end

      Apartment.adapter = V4IntegrationHelper.build_adapter(config)
      Apartment.activate!
      Apartment::Tenant.init

      expect(Apartment.pinned_models).to(include(LegacySetting))

      LegacySetting.create!(key: 'legacy', value: 'works')
      Apartment::Tenant.switch('tenant_a') do
        expect(LegacySetting.find_by(key: 'legacy').value).to(eq('works'))
      end
    end
  end

  context 'concurrent pinned model access', :stress do
    it 'two threads in different tenants both read/write the pinned model to default' do
      GlobalSetting.create!(key: 'shared', value: 'initial')

      threads = 2.times.map do |i|
        Thread.new do
          Apartment::Tenant.switch('tenant_a') do
            GlobalSetting.create!(key: "thread_#{i}", value: "val_#{i}")
            sleep(0.01) # brief yield to increase interleaving
            GlobalSetting.find_by(key: "thread_#{i}")
          end
        end
      end

      threads.each(&:join)
      expect(GlobalSetting.count).to(eq(3)) # initial + 2 threads
    end
  end
end
```

- [ ] **Step 2: Run integration tests on SQLite**

Run: `bundle exec appraisal rails-8.1-sqlite3 rspec spec/integration/v4/excluded_models_spec.rb -v`
Expected: All pass — this is the main proof that the `ConnectionHandling` fix works for database-per-tenant.

- [ ] **Step 3: Run integration tests on PostgreSQL (if available)**

Run: `DATABASE_ENGINE=postgresql bundle exec appraisal rails-8.1-postgresql rspec spec/integration/v4/excluded_models_spec.rb -v`
Expected: All pass.

- [ ] **Step 4: Run integration tests on MySQL (if available)**

Run: `DATABASE_ENGINE=mysql bundle exec appraisal rails-8.1-mysql2 rspec spec/integration/v4/excluded_models_spec.rb -v`
Expected: All pass.

- [ ] **Step 5: Run full integration suite to check for regressions**

Run: `bundle exec appraisal rails-8.1-sqlite3 rspec spec/integration/v4/ -v`
Expected: All pass.

- [ ] **Step 6: Commit**

```bash
git add spec/integration/v4/excluded_models_spec.rb
git commit -m "test: comprehensive pinned model integration tests

Covers all strategies (schema, database-per-tenant), ApplicationRecord
topology, STI inheritance, config.excluded_models shim, concurrent
access. Removes pending guards for non-PG engines."
```

---

### Task 8: Rubocop + Final Verification

**Files:**
- All changed files

- [ ] **Step 1: Run rubocop on all changed files**

Run: `bundle exec rubocop lib/apartment/concerns/model.rb lib/apartment.rb lib/apartment/patches/connection_handling.rb lib/apartment/adapters/abstract_adapter.rb lib/apartment/tenant.rb lib/apartment/config.rb spec/unit/concerns/model_spec.rb spec/unit/patches/connection_handling_spec.rb spec/unit/adapters/abstract_adapter_spec.rb spec/integration/v4/excluded_models_spec.rb`

Fix any offenses.

- [ ] **Step 2: Run full unit test suite**

Run: `bundle exec rspec spec/unit/ -v`
Expected: All pass.

- [ ] **Step 3: Run full integration suite across engines**

Run:
```bash
bundle exec appraisal rails-8.1-sqlite3 rspec spec/integration/v4/ --format progress
DATABASE_ENGINE=postgresql bundle exec appraisal rails-8.1-postgresql rspec spec/integration/v4/ --format progress
DATABASE_ENGINE=mysql bundle exec appraisal rails-8.1-mysql2 rspec spec/integration/v4/ --format progress
```
Expected: All pass.

- [ ] **Step 4: Fix any failures and commit fixes**

- [ ] **Step 5: Final commit with any rubocop/test fixes**

```bash
git add -u
git commit -m "chore: rubocop fixes for Phase 7.1"
```

---

## Deferred from Design Spec

These items from the design spec are intentionally deferred to avoid scope creep:

- **Table existence validation** (`validate_pinned_tables` config) — boot/migrate ordering makes this fragile. Current behavior (no validation) matches v3. Add in a follow-up if real apps hit confusing errors.
- **`has_many :through` pinned model test** — cross-DB joins are engine-specific and complex. Document behavior rather than test exhaustively.
- **`connects_to` coexistence test** — pre-existing issue, not introduced by Phase 7.1. Verify manually if needed.
