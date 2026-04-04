# Phase 7.1: Excluded Models Fix + Apartment::Model Concern

## Overview

Phase 7.1 fixes excluded model isolation for database-per-tenant strategies (MySQL, SQLite, PG database mode) and introduces `Apartment::Model` with `pin_tenant` as the primary API for declaring models that bypass tenant switching. `config.excluded_models` is deprecated with a compatibility shim.

**Primary goal:** Excluded models work correctly across all tenant strategies, not just PG schemas.

**Secondary goals:**
- Model-level `pin_tenant` DSL aligned with Rails conventions
- `ConnectionHandling` respects pinned model connections
- Hardened `process_pinned_models` with validation
- Comprehensive test matrix (all strategies, edge cases, multi-db coexistence)

## Context & Motivation

### The Bug: ConnectionHandling Overrides Excluded Model Connections

`ConnectionHandling#connection_pool` (Phase 2.3) intercepts `ActiveRecord::Base.connection_pool` and returns a tenant-specific pool when `Current.tenant` is set. It never checks whether the calling model class has its own pinned connection established by `process_excluded_models`.

For PG schema strategy, this is masked: the excluded model's table lives in `public` schema, which is accessible from any `search_path`. For database-per-tenant strategies (MySQL, SQLite, PG database), the override points to a different database entirely — the excluded model's table doesn't exist there.

Three specs in `spec/integration/v4/excluded_models_spec.rb` are `pending` for non-PG engines, documenting this gap.

### Why `Apartment::Model` Instead of Just Fixing `ConnectionHandling`

`config.excluded_models` is a centralized string list that requires `constantize` at boot time (fragile with Zeitwerk), scatters the "this model is global" decision away from the model, and only supports pinning to the default tenant.

Rails convention is model-level declaration: `belongs_to`, `has_many`, `connects_to`, `acts_as_paranoid`. `pin_tenant` follows the imperative verb pattern established by the ecosystem and places the declaration where it belongs — in the model file.

Prior art: `lib/apartment/concerns/model.rb` from PR #327 (4.0.0.alpha1, `man/spec-restart` branch, SHA 41776920).

**Correction to Phase 2.3 design:** `docs/designs/phase-2.3-connection-handling.md` suggested `super` would find the right pool for `connects_to` models. Phase 7.1's analysis shows this is not the case — the prepend intercepts before `super` can route via `connection_specification_name`. The `connects_to` coexistence issue is pre-existing; Phase 7.1 addresses the Apartment-specific case (pinned models) via explicit registry.

## Design

### 1. `Apartment::Model` Concern

**File:** `lib/apartment/concerns/model.rb`

```ruby
module Apartment
  module Model
    extend ActiveSupport::Concern

    class_methods do
      # Declare this model as pinned to the default tenant.
      # Pinned models bypass tenant switching in ConnectionHandling —
      # their connection always targets the default tenant's database/schema.
      #
      # Must be called after `include Apartment::Model`. Safe to call
      # before or after Apartment.activate! (deferred processing handles both).
      #
      # Idempotent: no-op if this class (or a parent) is already pinned.
      # Uses connection_specification_name as the ground truth — class instance
      # variables don't inherit, but AR connection ownership does.
      def pin_tenant
        return if apartment_pinned?

        Apartment.register_pinned_model(self)
        @apartment_pinned = true

        # If Apartment is already activated, process immediately (Zeitwerk autoload path).
        # Otherwise, activate! will process all registered models.
        Apartment.process_pinned_model(self) if Apartment.activated?
      end

      def apartment_pinned?
        # Check class ivar first (set by pin_tenant on this exact class),
        # then walk superclass chain for inherited pins.
        # Does NOT use connection_specification_name — that heuristic is
        # unsafe with ApplicationRecord (see ConnectionHandling section).
        return true if @apartment_pinned == true
        return false unless superclass.respond_to?(:apartment_pinned?)

        superclass.apartment_pinned?
      end
    end
  end
end
```

**Usage:**

```ruby
class GlobalSetting < ApplicationRecord
  include Apartment::Model
  pin_tenant
end
```

**STI / subclass semantics:** Pinning inherits via Rails' `connection_specification_name`. If `GlobalSetting` is pinned and `AdminSetting < GlobalSetting`, `AdminSetting` shares the pinned connection because `connection_specification_name` is inherited through the class hierarchy. Calling `pin_tenant` on a subclass whose parent is already pinned is a no-op — `apartment_pinned?` detects the inherited spec name divergence and returns `true`.

**Third-party models:** Models from gems cannot `include Apartment::Model` without monkeypatching. The deprecated `config.excluded_models` path handles this case (see section 4).

### 2. `ConnectionHandling` Fix

**File:** `lib/apartment/patches/connection_handling.rb`

Add an early return after the three existing guards (`tenant.nil?`, `default_tenant`, `pool_manager`), before tenant pool resolution:

```ruby
# Skip tenant override for Apartment pinned models.
# Uses explicit registry (not connection_specification_name heuristic)
# because ApplicationRecord subclasses have a different spec name than
# ActiveRecord::Base while sharing the same pool — a spec-name comparison
# would incorrectly bypass tenant routing for ALL models in standard Rails apps.
return super if self != ActiveRecord::Base && Apartment.pinned_model?(self)
```

**Why explicit registry, not `connection_specification_name` heuristic:**

The original design proposed comparing `connection_specification_name` against `ActiveRecord::Base.connection_specification_name`. This is unsafe in standard Rails apps:

- `ActiveRecord::Base.connection_specification_name` → `"ActiveRecord::Base"`
- `ApplicationRecord.connection_specification_name` → `"ApplicationRecord"` (abstract class)
- `User.connection_specification_name` → `"ApplicationRecord"` (inherited)

These differ even though they resolve to the same pool via Rails' hierarchical lookup. A spec-name comparison would cause every `ApplicationRecord` subclass to bypass tenant routing — a severe regression.

The explicit registry avoids this entirely: only models registered via `pin_tenant` or `config.excluded_models` are bypassed.

**`Apartment.pinned_model?` implementation:**

```ruby
def self.pinned_model?(klass)
  klass.ancestors.any? { |a| a.is_a?(Class) && pinned_models.include?(a) }
end
```

Walks the class hierarchy (not the full ancestor chain of modules) against the `pinned_models` set. Handles STI: if `GlobalSetting` is pinned, `AdminSetting < GlobalSetting` is caught because `GlobalSetting` appears in `AdminSetting.ancestors`. Short-circuits on first match. Ancestor chains are typically 3-5 classes; `Concurrent::Set#include?` is O(1).

**Placement:** After `return super unless Apartment.pool_manager` (existing line 18), before `role = ActiveRecord::Base.current_role` (existing line 20).

**`connects_to` models (known limitation):** Models using Rails' `connects_to` for multi-database setups are NOT covered by this guard. The current `ConnectionHandling` patch (pre-Phase 7.1) already misroutes them during tenant switches — this is a pre-existing issue, not introduced here. Phase 7.1's `connects_to` coexistence test verifies we don't make it worse. A general fix (e.g., pool identity comparison via `super`) is deferred to a future phase if needed.

**Test requirement:** Integration tests MUST use `ApplicationRecord` (or an abstract base class) for tenant-participating models, not just `Class.new(ActiveRecord::Base)`, to validate the guard works in real Rails app topology.

### 3. `process_pinned_models` (replaces `process_excluded_models`)

**File:** `lib/apartment/adapters/abstract_adapter.rb`

Rename `process_excluded_models` to `process_pinned_models`. Changes:

1. **Source:** Iterates `Apartment.pinned_models` (populated by `pin_tenant` and the `excluded_models` shim) instead of `config.excluded_models`
2. **Table existence validation:** Before calling `establish_connection`, verify the model's table exists in the default database. On failure, raise `Apartment::ConfigurationError` with an actionable message naming the model, expected table, and default tenant. **Boot/migrate ordering:** If `activate!` runs before migrations (e.g., `rails db:migrate`), the table may not exist yet. The validation should be skippable via `Apartment.config.validate_pinned_tables` (default `true`), or deferred to first use
3. **Schema strategy table_name rewrite:** Unchanged — prefix with `default_tenant.` for schema strategy
4. **Idempotent:** Skip models where `@apartment_connection_established` is already set (class-level ivar, not `connection_specification_name` comparison — same `ApplicationRecord` baseline issue applies here)

`process_excluded_models` becomes an alias that emits a deprecation warning and delegates to `process_pinned_models`.

### 4. `config.excluded_models` Deprecation Shim

**File:** `lib/apartment/config.rb`

`excluded_models=` setter emits a deprecation warning:

```
[Apartment] DEPRECATION: config.excluded_models is deprecated and will be removed in v5.
Use `include Apartment::Model` and `pin_tenant` in each model instead.
For third-party gem models, use config.excluded_models as a transitional escape hatch.
```

**Processing:** During `Apartment.activate!`, after processing `pinned_models`, iterate `config.excluded_models`, resolve each string to a constant, call `Apartment.register_pinned_model(klass)`, then `process_pinned_model(klass)`. Skip models already in `pinned_models` (duplicate protection).

**Boot-time validation:** If a model appears in both `config.excluded_models` and declares `pin_tenant`, `activate!` warns about the duplicate and skips the config-driven registration.

### 5. `Apartment` Module Additions

**File:** `lib/apartment.rb`

```ruby
module Apartment
  # Registry of models that declared pin_tenant.
  # Populated at class load time, processed during activate!.
  # Uses Concurrent::Set for thread safety (Zeitwerk autoload in threaded servers).
  # concurrent-ruby is already a Rails dependency via ActiveSupport.
  def self.pinned_models
    @pinned_models ||= Concurrent::Set.new
  end

  def self.register_pinned_model(klass)
    pinned_models.add(klass)
  end

  # Check if a class (or any of its ancestors) is a pinned model.
  # Used by ConnectionHandling to skip tenant pool routing.
  # Walks the class hierarchy (short-circuits on first match).
  def self.pinned_model?(klass)
    klass.ancestors.any? { |a| a.is_a?(Class) && pinned_models.include?(a) }
  end

  def self.activated?
    @activated == true
  end

  def self.process_pinned_model(klass)
    adapter&.process_pinned_model(klass)
  end
end
```

`activate!` sets `@activated = true` after calling `process_pinned_models`.

**Reset:** `clear_config` must also reset `@pinned_models = nil` and `@activated = false` to prevent cross-test leakage.

### 6. Test Matrix

**Updated `excluded_models_spec.rb`** — remove `pending` guards, all specs run on all engines:

| Spec | PG schema | PG database | MySQL | SQLite |
|------|-----------|-------------|-------|--------|
| `pin_tenant` establishes dedicated connection | pass | pass | pass | pass |
| `pin_tenant` is idempotent | pass | pass | pass | pass |
| Pinned model queries target default DB | pass (existing) | pass (new) | pass (new) | pass (new) |
| Pinned model data persists across switches | pass (existing) | pass (new) | pass (new) | pass (new) |
| Pinned model writes inside tenant block land in default | pass (existing) | pass (new) | pass (new) | pass (new) |

**New specs:**

| Spec | Strategy | Notes |
|------|----------|-------|
| `has_many :through` pinned model | PG schema | Join works via search_path |
| `has_many :through` pinned model | MySQL/SQLite | Expect clear error (cross-DB join) or skip with rationale |
| Concurrent pinned model access (2 threads, different tenants) | All | Both read/write default DB |
| `connects_to` multi-db model coexistence | All | Verify no worse than pre-7.1 (known pre-existing limitation) |
| ApplicationRecord tenant model topology | All | Tenant routing works when models inherit from abstract ApplicationRecord |
| STI subclass of pinned model | All | Inherits pinned behavior |
| Pinned model declared after `activate!` | All | Zeitwerk autoload path |
| Duplicate pin (config + concern) | All | Warning emitted, no error |
| `config.excluded_models` shim | All | Deprecation warning, functional |
| Table existence validation failure | All | Actionable `ConfigurationError` |

**Rails version coverage:** Appraisal matrix (7.2 / 8.0 / 8.1) covers `connection_specification_name` stability.

## Files Changed

| File | Change |
|------|--------|
| `lib/apartment/concerns/model.rb` | **New.** `Apartment::Model` concern with `pin_tenant` |
| `lib/apartment/patches/connection_handling.rb` | Early return for pinned/non-Base-spec models |
| `lib/apartment/adapters/abstract_adapter.rb` | `process_pinned_models` (rename + hardening), `process_pinned_model` (single model), deprecation alias |
| `lib/apartment.rb` | `pinned_models` registry, `register_pinned_model`, `pinned_model?`, `activated?`, `process_pinned_model` |
| `lib/apartment/config.rb` | Deprecation warning on `excluded_models=` |
| `lib/apartment/railtie.rb` | Call `process_pinned_models` in `activate!`, set `@activated` |
| `lib/apartment/tenant.rb` | `init` calls `process_pinned_models` instead of `process_excluded_models` |
| `spec/integration/v4/excluded_models_spec.rb` | Remove pending guards, add `pin_tenant` usage, expand matrix |
| `spec/unit/concerns/model_spec.rb` | **New.** Unit tests for `Apartment::Model` concern |
| `spec/unit/adapters/abstract_adapter_spec.rb` | Update `process_excluded_models` tests to cover `process_pinned_models` |

## Out of Scope (Phase 7.2 or Phase 8)

- **MySQL Migrator RBAC tests:** Port `migrator_rbac_spec.rb` to MySQL. Infrastructure exists (`RbacHelper.provision_mysql_roles!`, `setup_connects_to!`). ~3 new examples.
- **CI meta-confidence guard:** Replace `< 1` threshold with meaningful minimums (PG ~15, MySQL ~8) after this phase's specs stabilize the example counts.
- **`pin_tenant(:tenant_name)` — pin to non-default tenant:** API slot reserved but not implemented. Current `pin_tenant` always pins to default.
- **`ConfigurationMap` / runtime tenant config registry:** Prior art in PR #327. Evaluate for Phase 8 if dynamic tenant configs beyond `tenants_provider` are needed.
- **`Apartment::Logger` / tagged logging:** DX polish from PR #327. Phase 8 candidate.
- **Upgrade guide (`docs/4.0-Upgrade.md`):** Port useful sections from PR #327 into Phase 8 docs.
