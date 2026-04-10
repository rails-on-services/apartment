# Deferred pin_tenant Processing — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Defer `process_pinned_model` until after the class body closes when `pin_tenant` is called post-activation, so `self.table_name` can appear anywhere in the class body without ordering bugs.

**Architecture:** Replace the immediate `Apartment.process_pinned_model(self)` call in `pin_tenant` with a one-shot `TracePoint(:end, :raise)` listener constrained to `Thread.current`. The trace fires after the class's closing `end`, then disables itself. `:raise` handling prevents trace leaks if the class body fails to load.

**Tech Stack:** Ruby, RSpec, TracePoint API, Appraisal (multi-Rails testing)

**Design spec:** `docs/designs/v4-deferred-pin-tenant-processing.md`

---

### Task 1: Implement TracePoint deferral in pin_tenant

**Files:**
- Modify: `lib/apartment/concerns/model.rb:20-29`

- [ ] **Step 1: Replace the immediate processing branch**

In `lib/apartment/concerns/model.rb`, replace the `pin_tenant` method (lines 20-29):

```ruby
def pin_tenant
  return if apartment_pinned?

  @apartment_pinned = true
  Apartment.register_pinned_model(self)

  # If Apartment is already activated, process immediately (Zeitwerk autoload path).
  # Otherwise, activate! will process all registered models.
  Apartment.process_pinned_model(self) if Apartment.activated?
end
```

With:

```ruby
def pin_tenant
  return if apartment_pinned?

  @apartment_pinned = true
  Apartment.register_pinned_model(self)

  return unless Apartment.activated?

  # Defer processing until the class body closes, so self.table_name
  # and other class-level declarations are visible. Uses TracePoint(:end)
  # to detect the class's closing `end` keyword.
  # :raise disables unconditionally to prevent trace leaks — even if
  # the raise originates in a nested class/module (t.self != klass).
  klass = self
  trace = TracePoint.new(:end, :raise) do |t|
    if t.event == :raise
      trace.disable
    elsif t.self == klass
      trace.disable
      Apartment.process_pinned_model(klass)
    end
  end
  trace.enable(target_thread: Thread.current)
end
```

- [ ] **Step 2: Run existing unit tests to verify nothing breaks**

Run: `bundle exec rspec spec/unit/concerns/model_spec.rb --format documentation`
Expected: The "processes immediately when Apartment is already activated" test will FAIL because `process_pinned_model` is now deferred (not called during `pin_tenant` when using `Class.new` — TracePoint fires on the block's `end`, but the expect already ran).

- [ ] **Step 3: Commit**

```bash
git add lib/apartment/concerns/model.rb
git commit -m "Defer pin_tenant processing via TracePoint(:end, :raise)

When activated? is true, pin_tenant now registers a one-shot
TracePoint that fires after the class body closes, ensuring
self.table_name and other declarations are visible. :raise
handling prevents trace leaks on class body failure.

Co-Authored-By: henkesn <14108170+henkesn@users.noreply.github.com>
Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Update unit tests for deferred behavior

**Files:**
- Modify: `spec/unit/concerns/model_spec.rb`

- [ ] **Step 1: Replace the "processes immediately" test**

In `spec/unit/concerns/model_spec.rb`, find and replace the test at around line 43:

```ruby
it 'processes immediately when Apartment is already activated' do
  klass = Class.new(ActiveRecord::Base) do
    include Apartment::Model
  end
  stub_const('LateLoadedModel', klass)

  expect(Apartment).to(receive(:activated?).and_return(true))
  expect(Apartment).to(receive(:process_pinned_model).with(LateLoadedModel))

  klass.pin_tenant
end
```

With:

```ruby
it 'defers processing until class body closes when activated' do
  allow(Apartment).to(receive(:activated?).and_return(true))

  processed = false
  allow(Apartment).to(receive(:process_pinned_model)) { processed = true }

  # Class.new with a block simulates a class body — TracePoint(:end)
  # fires when the block closes. pin_tenant should NOT process inline.
  klass = Class.new(ActiveRecord::Base) do
    include Apartment::Model
    pin_tenant
    # At this point, process_pinned_model should NOT have been called yet.
  end
  stub_const('DeferredModel', klass)

  # After the class body closes, TracePoint fires and processes.
  expect(processed).to(be(true))
  expect(Apartment.pinned_models).to(include(klass))
end
```

- [ ] **Step 2: Add test for raise cleanup**

Add after the deferred processing test:

```ruby
it 'disables trace if class body raises (no leak)' do
  allow(Apartment).to(receive(:activated?).and_return(true))
  process_calls = []
  allow(Apartment).to(receive(:process_pinned_model)) { |k| process_calls << k }

  expect {
    Class.new(ActiveRecord::Base) do
      include Apartment::Model
      pin_tenant
      raise 'simulated load failure'
    end
  }.to(raise_error(RuntimeError, 'simulated load failure'))

  # The raise should have disabled the trace. Verify by defining
  # a second pinned model — it should get its OWN trace and process
  # exactly once (proving the first trace is dead, not double-firing).
  second = Class.new(ActiveRecord::Base) do
    include Apartment::Model
    pin_tenant
  end
  stub_const('SecondModel', second)

  expect(process_calls).to(eq([second]))
end
```

- [ ] **Step 3: Add test confirming non-activated path is unchanged**

The existing "defers processing when Apartment is not yet activated" test should still pass. Verify it's still present and hasn't changed:

```ruby
it 'defers processing when Apartment is not yet activated' do
  expect(Apartment).to(receive(:activated?).and_return(false))
  expect(Apartment).not_to(receive(:process_pinned_model))

  klass = Class.new(ActiveRecord::Base) do
    include Apartment::Model
  end
  stub_const('EarlyModel', klass)

  klass.pin_tenant
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/unit/concerns/model_spec.rb --format documentation`
Expected: all pass

- [ ] **Step 5: Commit**

```bash
git add spec/unit/concerns/model_spec.rb
git commit -m "Update model_spec for deferred pin_tenant processing

Test deferred processing via TracePoint (class body closes before
process_pinned_model runs). Test :raise cleanup (trace disabled on
class body failure, no leak). Existing non-activated path unchanged.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Add integration test for table_name ordering

**Files:**
- Modify: `spec/integration/v4/excluded_models_spec.rb`

- [ ] **Step 1: Add deferred qualification test**

In `spec/integration/v4/excluded_models_spec.rb`, add a new context block after the `context 'STI subclass of pinned model'` block (which ends around line 188, before `context 'config.excluded_models shim'`):

```ruby
context 'deferred pin_tenant processing (table_name after pin_tenant)' do
  it 'qualifies explicit table_name declared after pin_tenant' do
    # Simulate the CampusESP pattern: pin_tenant above self.table_name.
    # The before block already called activate!, so activated? is true.
    # With deferral, process_pinned_model runs after the class body closes,
    # so it sees the explicit table_name.
    stub_const('DeferredPinned', Class.new(ApplicationRecord) do
      include Apartment::Model
      pin_tenant                            # declared first
      self.table_name = 'global_settings'   # declared after
    end)

    if Apartment.adapter.shared_pinned_connection?
      expect(DeferredPinned.table_name).to(end_with('.global_settings'))
    else
      expect(DeferredPinned.table_name).to(eq('global_settings'))
    end
  end

  it 'qualifies convention table_name with pin_tenant anywhere in body' do
    stub_const('ConventionDeferred', Class.new(ApplicationRecord) do
      include Apartment::Model
      pin_tenant
      # No explicit self.table_name — convention naming
    end)

    if Apartment.adapter.shared_pinned_connection?
      expect(ConventionDeferred.table_name).to(include('.'))
    end
  end
end
```

- [ ] **Step 2: Run integration tests**

Run: `bundle exec appraisal rails-8.1-sqlite3 rspec spec/integration/v4/excluded_models_spec.rb --format documentation`
Expected: all pass (deferred tests exercise the correct path per adapter)

- [ ] **Step 3: Commit**

```bash
git add spec/integration/v4/excluded_models_spec.rb
git commit -m "Add integration test for deferred pin_tenant qualification

Mirrors the CampusESP pattern: pin_tenant above self.table_name.
Verifies qualification uses the explicit table name (not convention)
regardless of declaration order. Adapter-aware assertions.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Update documentation

**Files:**
- Modify: `docs/upgrading-to-v4.md`
- Modify: `lib/apartment/CLAUDE.md`

- [ ] **Step 1: Add note to upgrade guide**

In `docs/upgrading-to-v4.md`, find the "Pinned Model Connections" section (around line 121). Add at the end of that section, before "Key config options for pool tuning:":

```markdown
`pin_tenant` defers processing until the class body closes (when called after `Apartment.activate!`), so `self.table_name` can appear anywhere in the class body. No ordering requirement between `pin_tenant` and `self.table_name`.
```

- [ ] **Step 2: Update lib/apartment/CLAUDE.md**

In `lib/apartment/CLAUDE.md`, find the `concerns/model.rb` section (around line 77). Add after the existing "Lifecycle" paragraph:

```markdown
**Deferred processing:** When `Apartment.activated?` is true (Zeitwerk lazy-load path), `pin_tenant` defers `process_pinned_model` via a one-shot `TracePoint(:end, :raise)` constrained to `Thread.current`. The trace fires after the class body closes, ensuring `self.table_name` and other declarations are visible. `:raise` handling disables the trace if the class body fails to load (prevents trace leaks). Models loaded before `activate!` are unaffected (processed in batch by `Tenant.init`). Reopening a pinned class does not re-trigger processing (idempotent via `apartment_pinned?`).
```

- [ ] **Step 3: Commit**

```bash
git add docs/upgrading-to-v4.md lib/apartment/CLAUDE.md
git commit -m "Document deferred pin_tenant processing

Upgrade guide: no ordering requirement between pin_tenant and
self.table_name. CLAUDE.md: TracePoint(:end, :raise) deferral
mechanism, thread safety, raise cleanup, reopen edge case.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Run full test suite and rubocop

**Files:** None (verification only)

- [ ] **Step 1: Run rubocop on changed files**

Run: `bundle exec rubocop lib/apartment/concerns/model.rb spec/unit/concerns/model_spec.rb spec/integration/v4/excluded_models_spec.rb`
Expected: no offenses

- [ ] **Step 2: Run unit tests**

Run: `bundle exec rspec spec/unit/ --format progress`
Expected: all pass, 0 failures

- [ ] **Step 3: Run unit tests across Rails versions**

Run: `bundle exec appraisal rspec spec/unit/ --format progress`
Expected: all pass across all Rails versions

- [ ] **Step 4: Run integration tests (SQLite)**

Run: `bundle exec appraisal rails-8.1-sqlite3 rspec spec/integration/v4/ --format documentation`
Expected: all pass

- [ ] **Step 5: Run integration tests (PostgreSQL, if available)**

Run: `DATABASE_ENGINE=postgresql bundle exec appraisal rails-8.1-postgresql rspec spec/integration/v4/ --format documentation`
Expected: all pass; deferred qualification tests verify `public.global_settings` prefix
