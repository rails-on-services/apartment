# Deferred pin_tenant Processing

## Status

Draft

## Problem

When `pin_tenant` is called during class body evaluation and `Apartment.activated?` is true, `process_pinned_model` runs immediately. If `self.table_name = 'custom'` appears later in the class body, it hasn't been evaluated yet. The gem sees no explicit table name, takes the convention path (`table_name_prefix` + `reset_table_name`), qualifies the name incorrectly (e.g., `public.engagement_reports`), and then line 23's `self.table_name = 'reports'` overwrites the qualification silently. The model queries the wrong schema.

```ruby
class EngagementReport < ApplicationRecord
  include Apartment::Model
  pin_tenant                          # line 4: processes immediately, sees no @table_name

  belongs_to :instance
  # ... 18 lines of associations, scopes, validations ...
  self.table_name = 'reports'         # line 23: overwrites qualification
end
```

This only manifests when:
1. `Apartment.activated?` is true (Railtie ran `config.after_initialize`)
2. The model is autoloaded by Zeitwerk (`eager_load = false` in dev/test)
3. `self.table_name` appears after `pin_tenant` in the class body

Condition 1+2 is the default in every Rails dev/test environment. Condition 3 is natural — developers put `include` + DSL calls at the top, then model configuration lower.

## Prior Art

**`acts_as_tenant`** — single DSL call (`acts_as_tenant(:account, has_global_records: true)`) that bundles all setup. Still documents "call after `belongs_to`" as an ordering contract, so macro order is not entirely eliminated — but the split-macro problem (two separate calls that depend on each other) is avoided.

**`activerecord-multi-tenant` (Citus)** — same pattern. `multi_tenant(:account)` is one call.

**Classic apartment v3** — central `config.excluded_models = ['User', 'Company']` with string names, constantized at boot. Sidesteps class-body ordering because registration doesn't happen during class evaluation.

**Ruby `TracePoint(:end)`** — fires when a class/module body closes. Used in [Stack Overflow patterns](https://stackoverflow.com/questions/72791594) for deferring side effects until a class is fully defined. Not used by multi-tenancy gems specifically, but a well-known Ruby idiom.

None of these gems implement deferred processing via TracePoint. The dominant patterns are either single-DSL (no ordering dependency) or central config (no class-body execution). Apartment's `pin_tenant` is a split macro (register + process) that runs during class evaluation — a design choice we made for co-location. This fix completes that design by making `pin_tenant` robust to ordering.

## Design

### TracePoint Deferral in pin_tenant

When `pin_tenant` is called and `Apartment.activated?` is true, instead of calling `Apartment.process_pinned_model(self)` immediately, register a one-shot `TracePoint(:end)` listener that fires after the class body closes:

```ruby
def pin_tenant
  return if apartment_pinned?

  @apartment_pinned = true
  Apartment.register_pinned_model(self)

  return unless Apartment.activated?

  klass = self
  trace = TracePoint.new(:end, :raise) do |t|
    if t.event == :raise
      # Disable unconditionally on any raise — even from nested
      # classes/modules (t.self != klass). Prevents trace leak.
      trace.disable
    elsif t.self == klass
      trace.disable
      Apartment.process_pinned_model(klass)
    end
  end
  trace.enable(target_thread: Thread.current)
end
```

**What changes:** Only the `Apartment.activated?` branch. The `activate!` -> `process_pinned_models` path (models loaded before activation) is unchanged — by the time `Tenant.init` runs, all class bodies have closed and `self.table_name` is visible.

**What stays the same:**
- `apartment_pinned?` idempotency guard
- `@apartment_pinned` flag setting
- `register_pinned_model` registration
- `process_pinned_model` logic (dual-path, concern methods)
- Models loaded before `activate!` (processed in batch by `Tenant.init`)

### How TracePoint(:end) Works

Ruby's `:end` event fires when a `class` or `module` keyword's matching `end` is reached in source-parsed files. For `Class.new { }` anonymous classes (used in tests and runtime metaprogramming), `:end` does NOT fire — `:b_return` (block return) fires instead. The implementation listens for both `:end` and `:b_return` to handle both paths. The TracePoint callback receives a `TracePoint` object where `t.self` is the class/module being closed.

**Scope:** The trace is active only from `pin_tenant` (mid-class body) until the class's closing `end`. In practice, this is microseconds of class body evaluation. Not on the request hot path.

**Filtering:** `t.self == klass` ensures we only fire for our class. Other classes being defined concurrently (threaded autoload) are ignored.

**One-shot:** `trace.disable` inside the callback prevents the listener from firing again. No accumulation of listeners over time.

**Cost:** With `target_thread: Thread.current`, MRI only invokes the callback for `:end` events in the current thread. The only events between enable and disable are nested modules/classes within the model's body (if any) and the model's own closing `end`. Negligible.

### Edge Cases

**Models loaded before `activate!` (boot-time eager load):** Not affected. `Apartment.activated?` is false, so `pin_tenant` only registers. `Tenant.init` processes all registered models in batch after `activate!` runs. Class bodies are fully closed by then.

**Reopened classes:** If someone reopens a model class after the initial definition, `pin_tenant` returns early (idempotent via `apartment_pinned?`). No second TracePoint. If they change `self.table_name` in the reopen, the gem doesn't re-qualify. This is the same behavior as today — deferral doesn't make it worse. Document as a known edge case.

**Nested classes/modules inside the model:** The `:end` event fires for nested definitions too, but `t.self == klass` filters them out. Only the model's own closing `end` matches.

**Thread safety:** `TracePoint#enable` without a block enables the trace **globally across all threads** by default (Ruby docs: "`target_thread` defaults to the current thread" only when a block is given). We use `trace.enable(target_thread: Thread.current)` to constrain the trace to the thread evaluating the class body. This prevents the callback from firing for `:end` events in other threads (e.g., concurrent Puma workers autoloading different classes). The `t.self == klass` guard provides a second layer of defense.

**`eager_load = true` (production):** All models are loaded during boot before `activate!` runs. `pin_tenant` sees `activated? == false`, registers only, no TracePoint. `Tenant.init` processes the batch. No change from today.

**TracePoint leak on class body raise:** If the class body raises during evaluation, Ruby unwinds without reaching the closing `end`, so `:end` for that class never fires. The trace stays enabled for that thread — the `t.self == klass` guard prevents wrong work, but the callback still runs on every subsequent `:end` event in the thread (cheap per-invocation, bad if accumulated across many failed loads).

Mitigation: listen for `:raise` in the same TracePoint. On any `:raise` event, disable the trace **unconditionally** (not gated on `t.self == klass`). This is necessary because a raise inside a nested class/module within the model body would have `t.self` pointing to the nested class, not the model. Disabling on any raise is conservative but safe: the model is registered but unprocessed; it will fail on first use (class is broken anyway). See the code sketch in the Design section above.

Testing: add a unit test that simulates a class body raise after `pin_tenant` and asserts the trace is disabled (not leaked).

**Unprocessed pinned models (`Tenant.init`):** Separately from the TracePoint leak concern, `process_pinned_models` (called by `Tenant.init`) should process any registered models not yet marked as processed. This catches models whose processing was skipped for any reason (raise, race condition, etc.). This does NOT clean up a leaked TracePoint — it only ensures the model gets processed if still loadable.

**Fiber safety:** Class body evaluation (`class Foo ... end`) is synchronous Ruby code — no `Fiber.yield` occurs between `pin_tenant` and the closing `end` unless explicitly coded. Zeitwerk synchronizes autoload via a monitor/mutex (not fiber-aware scheduling). Fiber-based servers (Falcon) use fibers for IO concurrency, not class loading. `target_thread: Thread.current` covers all fibers within that thread (fibers share `Thread.current`), but the `t.self == klass` guard ensures only our class triggers processing. The real fiber concern for Apartment v4 is `CurrentAttributes` isolation (handled by the Railtie's `isolation_level` warning), not TracePoint deferral.

**JRuby / TruffleRuby:** `TracePoint` semantics and performance vary across Ruby implementations. This design targets MRI (CRuby). Alternative implementations are best-effort; CI should include MRI as the authoritative matrix.

### What Not To Do

**RuboCop cop for ordering:** Not needed for correctness once deferral is implemented. Could be offered as an optional, off-by-default style hint (`Severity: convention`) for teams that prefer `self.table_name` above `pin_tenant` for readability. Should not be a lint error or CI gate — the bug is fixed at the source.

**Central config fallback:** We deliberately moved from `excluded_models` to `pin_tenant` for co-location. Re-introducing central registration reverses that design decision. The shim exists for v3 compatibility only.

**`ActiveSupport.on_load`:** Wrong layer. `on_load` defers until a framework component loads, not until a class body closes. Doesn't solve the problem.

## Testing

### Unit Tests (model_spec.rb)

- `pin_tenant` when `activated?` is true does NOT call `process_pinned_model` immediately
- `pin_tenant` when `activated?` is true calls `process_pinned_model` after the class body closes (simulate with `Class.new` block)
- `pin_tenant` when `activated?` is false registers without TracePoint (existing behavior)
- Idempotency: second `pin_tenant` call doesn't register a second TracePoint
- Class body raise after `pin_tenant`: trace is disabled (not leaked), model stays registered but unprocessed

### Integration Test (new spec or addition to excluded_models_spec.rb)

Mirror the exact CampusESP failure:
- `eager_load = false` (default in test)
- `Apartment.activate!` before model autoload
- Model with `pin_tenant` above `self.table_name = 'custom'`
- Assert: model's `table_name` is qualified with the custom name (e.g., `public.custom` for PG schema, `myapp.custom` for MySQL), not the convention name
- Adapter-specific: PG schema uses `default_tenant` as prefix; MySQL uses `base_config['database']`; SQLite uses separate-pool path (no qualification). Tests should be conditional or adapter-aware.

### Negative Test

- Model with `pin_tenant` and NO explicit `self.table_name` — convention path still works correctly (table_name_prefix + reset_table_name produces `public.model_names`)

## Documentation

### Upgrade Guide Addition (docs/upgrading-to-v4.md)

Short note under Pinned Model Connections: "`pin_tenant` defers processing until the class body closes (when called after `Apartment.activate!`), so `self.table_name` can appear anywhere in the class body. No ordering requirement."

### CLAUDE.md Update (lib/apartment/CLAUDE.md)

Under concerns/model.rb: note that `pin_tenant` uses `TracePoint(:end)` for deferred processing when activated. Mention the reopen edge case.

## Out of Scope

- RuboCop cop for declaration order (optional off-by-default style hint is fine as a future add; not needed for correctness)
- Central config alternative to pin_tenant
- Deferred processing for `apartment_mark_pinned!` (shim path — models are fully defined by `Tenant.init` time)
