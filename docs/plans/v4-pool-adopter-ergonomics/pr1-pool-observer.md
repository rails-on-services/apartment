# PoolObserver + Observability Docs — Implementation Plan (PR 1)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `Apartment::PoolObserver`, a sink-agnostic subscriber (+ optional gauge sampler) for the gem's pool-lifecycle events, and `docs/observability.md` documenting the event/stats contract.

**Architecture:** A single `Concurrent`-backed class subscribes to the gem's `ActiveSupport::Notifications`, normalizes each event into a `Sample` value object, and forwards it to a caller-supplied `sink` callable. An optional `Concurrent::TimerTask` (same idiom as `PoolReaper`) emits gauge samples from `PoolManager#stats` plus an optional adopter-supplied `backend_count`. All sink/sampler calls are error-isolated — telemetry never raises into the gem's instrumentation or timer path. The gem ships no transport; the adopter's `sink` maps `Sample`s to its metrics backend.

**Tech Stack:** Ruby 3.3+ (`Data.define`), `concurrent-ruby` (`TimerTask`), `ActiveSupport::Notifications`. No database, no Rails required for the unit suite.

**Design spec:** `docs/designs/v4-pool-adopter-ergonomics.md` (component C + the observability half of D).

**Branch:** cut `feat/pool-observer` off `main` before Task 1.

---

### Task 1: File skeleton — `Sample` value object + constructor validation

**Files:**
- Create: `lib/apartment/pool_observer.rb`
- Test: `spec/unit/pool_observer_spec.rb`

- [ ] **Step 1: Write the failing test**

```ruby
# spec/unit/pool_observer_spec.rb
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe(Apartment::PoolObserver) do
  let(:samples) { Concurrent::Array.new }
  let(:sink) { ->(sample) { samples << sample } }

  describe '.new' do
    it 'raises ArgumentError when the sink is not callable' do
      expect { described_class.new(sink: 'not callable') }
        .to(raise_error(ArgumentError, /sink must be callable/))
    end

    it 'accepts a callable sink' do
      expect { described_class.new(sink: sink) }.not_to(raise_error)
    end
  end

  describe 'Sample' do
    it 'is a value object with the documented fields' do
      sample = described_class::Sample.new(
        name: :evict, kind: :counter, value: 1, dimensions: { reason: :idle }, payload: { tenant: 'acme' }
      )
      expect(sample).to(have_attributes(name: :evict, kind: :counter, value: 1,
                                        dimensions: { reason: :idle }, payload: { tenant: 'acme' }))
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/unit/pool_observer_spec.rb`
Expected: FAIL with `uninitialized constant Apartment::PoolObserver`

- [ ] **Step 3: Write minimal implementation**

```ruby
# lib/apartment/pool_observer.rb
# frozen_string_literal: true

require 'concurrent'

module Apartment
  # Sink-agnostic observer for the v4 pool lifecycle. Subscribes to the gem's
  # ActiveSupport::Notifications and forwards a normalized Sample to a caller-
  # supplied sink; optionally samples pool gauges on an interval. Ships no
  # transport — the adopter's sink maps Samples to CloudWatch/StatsD/logs/etc.
  # All sink/sampler calls are error-isolated: telemetry must never raise into
  # the gem's instrumentation or timer path. See docs/observability.md.
  class PoolObserver
    # name: Symbol (:evict, :tenant_pools_live, ...); kind: :counter | :gauge;
    # value: Numeric; dimensions: Hash (curated, e.g. { reason: :idle });
    # payload: the raw notification payload (counters) or {} (gauges).
    Sample = Data.define(:name, :kind, :value, :dimensions, :payload)

    def initialize(sink:, backend_count: nil)
      raise(ArgumentError, 'sink must be callable') unless sink.respond_to?(:call)

      @sink = sink
      @backend_count = backend_count
      @subscribers = []
      @sampler = nil
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/unit/pool_observer_spec.rb`
Expected: PASS (3 examples)

- [ ] **Step 5: Commit**

```bash
git add lib/apartment/pool_observer.rb spec/unit/pool_observer_spec.rb
git commit -m "PoolObserver: Sample value object + constructor validation"
```

---

### Task 2: `subscribe!` + `record_event` + `.install!` — counter samples

**Files:**
- Modify: `lib/apartment/pool_observer.rb`
- Test: `spec/unit/pool_observer_spec.rb`

- [ ] **Step 1: Write the failing tests**

```ruby
# Add inside the RSpec.describe block, after the 'Sample' describe.
  describe '#subscribe! / .install!' do
    subject(:observer) { described_class.install!(sink: sink) }

    after { observer.stop! }

    it 'forwards a subscribed event to the sink as a counter Sample' do
      observer
      Apartment::Instrumentation.instrument(:evict, tenant: 'acme', reason: :idle)

      sample = samples.find { |s| s.name == :evict }
      expect(sample).not_to(be_nil)
      expect(sample).to(have_attributes(kind: :counter, value: 1, dimensions: { reason: :idle }))
      expect(sample.payload).to(include(tenant: 'acme', reason: :idle))
    end

    it 'curates :reason into dimensions and leaves the rest in payload' do
      observer
      Apartment::Instrumentation.instrument(:cap_unmet, max_total: 5, current: 6, unevicted: 1)

      sample = samples.find { |s| s.name == :cap_unmet }
      expect(sample.dimensions).to(eq({}))
      expect(sample.payload).to(include(max_total: 5, current: 6, unevicted: 1))
    end

    it 'subscribes to all pool-lifecycle counter events' do
      observer
      %i[create evict cap_unmet skip_evict reaper_stopped].each do |event|
        Apartment::Instrumentation.instrument(event, {})
      end
      expect(samples.map(&:name)).to(include(:create, :evict, :cap_unmet, :skip_evict, :reaper_stopped))
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/unit/pool_observer_spec.rb -e subscribe`
Expected: FAIL with `undefined method 'install!'`

- [ ] **Step 3: Write minimal implementation**

```ruby
# Add to lib/apartment/pool_observer.rb inside class PoolObserver, after Sample.

    # Pool-lifecycle events forwarded as counters (value 1 each).
    COUNTER_EVENTS = %i[create evict cap_unmet skip_evict reaper_stopped].freeze

    # Build, subscribe, and (optionally) start the gauge sampler. Returns the
    # observer; call #stop! to tear it down. Idempotent subscription is NOT
    # guaranteed — install once per process (e.g. an after_initialize hook).
    def self.install!(sink:, sample_interval: nil, backend_count: nil)
      observer = new(sink: sink, backend_count: backend_count)
      observer.subscribe!
      observer.start_sampler!(interval: sample_interval) if sample_interval&.positive?
      observer
    end

    def subscribe!
      COUNTER_EVENTS.each do |event|
        subscriber = ActiveSupport::Notifications.subscribe("#{event}.apartment") do |_name, _start, _finish, _id, payload|
          record_event(event, payload || {})
        end
        @subscribers << subscriber
      end
      self
    end
```

```ruby
# Add a private section at the bottom of class PoolObserver.

    private

    def record_event(event, payload)
      dimensions = payload[:reason] ? { reason: payload[:reason] } : {}
      emit(Sample.new(name: event, kind: :counter, value: 1, dimensions: dimensions, payload: payload))
    rescue StandardError => e
      warn_failure("record_event(#{event})", e)
    end

    def emit(sample)
      @sink.call(sample)
    rescue StandardError => e
      warn_failure("sink(#{sample.name})", e)
    end

    def warn_failure(context, error)
      warn "[Apartment::PoolObserver] #{context} failed: #{error.class}: #{error.message}"
    end
```

> Note: `start_sampler!` and `stop!` are referenced by `install!`/specs but defined in Task 4. Add a temporary no-op `def stop!; @subscribers.each { |s| ActiveSupport::Notifications.unsubscribe(s) }; @subscribers.clear; end` and `def start_sampler!(interval:); end` now so Task 2 runs green; Task 4 replaces them with the full versions.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/unit/pool_observer_spec.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/apartment/pool_observer.rb spec/unit/pool_observer_spec.rb
git commit -m "PoolObserver: subscribe to pool events, forward counter Samples to the sink"
```

---

### Task 3: `sample!` — gauge samples (`tenant_pools_live` + optional `backend_connections`)

**Files:**
- Modify: `lib/apartment/pool_observer.rb`
- Test: `spec/unit/pool_observer_spec.rb`

- [ ] **Step 1: Write the failing tests**

```ruby
# Add inside the RSpec.describe block.
  describe '#sample!' do
    let(:stub_manager) { instance_double(Apartment::PoolManager, stats: { total_pools: 3, tenants: [] }) }

    before { allow(Apartment).to(receive(:pool_manager).and_return(stub_manager)) }

    it 'emits a tenant_pools_live gauge from PoolManager#stats' do
      observer = described_class.new(sink: sink)
      observer.sample!

      sample = samples.find { |s| s.name == :tenant_pools_live }
      expect(sample).to(have_attributes(kind: :gauge, value: 3, dimensions: {}, payload: {}))
    end

    it 'emits backend_connections when a backend_count callable is supplied' do
      observer = described_class.new(sink: sink, backend_count: -> { 42 })
      observer.sample!

      sample = samples.find { |s| s.name == :backend_connections }
      expect(sample).to(have_attributes(kind: :gauge, value: 42))
    end

    it 'skips backend_connections when backend_count returns nil' do
      observer = described_class.new(sink: sink, backend_count: -> { nil })
      observer.sample!

      expect(samples.map(&:name)).not_to(include(:backend_connections))
    end

    it 'reports zero pools when the manager is absent (unconfigured)' do
      allow(Apartment).to(receive(:pool_manager).and_return(nil))
      observer = described_class.new(sink: sink)
      observer.sample!

      expect(samples.find { |s| s.name == :tenant_pools_live }.value).to(eq(0))
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/unit/pool_observer_spec.rb -e sample!`
Expected: FAIL with `undefined method 'sample!'`

- [ ] **Step 3: Write minimal implementation**

```ruby
# Add to lib/apartment/pool_observer.rb as a PUBLIC method (above `private`).

    # One gauge pass: live tenant-pool count, plus the adopter's backend count
    # when supplied. Safe to call from start_sampler! or an external scheduler.
    def sample!
      total = Apartment.pool_manager&.stats&.fetch(:total_pools, 0) || 0
      emit(Sample.new(name: :tenant_pools_live, kind: :gauge, value: total, dimensions: {}, payload: {}))

      return unless @backend_count

      backends = @backend_count.call
      return if backends.nil?

      emit(Sample.new(name: :backend_connections, kind: :gauge, value: backends, dimensions: {}, payload: {}))
    rescue StandardError => e
      warn_failure('sample!', e)
    end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/unit/pool_observer_spec.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/apartment/pool_observer.rb spec/unit/pool_observer_spec.rb
git commit -m "PoolObserver: sample! emits tenant_pools_live + optional backend_connections gauges"
```

---

### Task 4: `start_sampler!` / `stop!` — lifecycle

**Files:**
- Modify: `lib/apartment/pool_observer.rb` (replace the Task 2 temporary stubs)
- Test: `spec/unit/pool_observer_spec.rb`

- [ ] **Step 1: Write the failing tests**

```ruby
# Add inside the RSpec.describe block.
  describe '#start_sampler! / #stop!' do
    let(:stub_manager) { instance_double(Apartment::PoolManager, stats: { total_pools: 2, tenants: [] }) }

    before { allow(Apartment).to(receive(:pool_manager).and_return(stub_manager)) }

    it 'runs sample! on the configured interval' do
      observer = described_class.new(sink: sink)
      observer.start_sampler!(interval: 0.05)
      sleep 0.15
      observer.stop!

      expect(samples.any? { |s| s.name == :tenant_pools_live }).to(be(true))
    end

    it 'stop! unsubscribes so later events no longer reach the sink' do
      observer = described_class.install!(sink: sink)
      observer.stop!
      samples.clear

      Apartment::Instrumentation.instrument(:evict, {})
      expect(samples).to(be_empty)
    end

    it 'stop! halts the sampler' do
      observer = described_class.new(sink: sink)
      observer.start_sampler!(interval: 0.05)
      observer.stop!
      sleep 0.1
      count = samples.size
      sleep 0.1
      expect(samples.size).to(eq(count))
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/unit/pool_observer_spec.rb -e sampler`
Expected: FAIL (the temporary `start_sampler!` is a no-op, so no `tenant_pools_live` sample appears)

- [ ] **Step 3: Write minimal implementation**

```ruby
# Replace the temporary stubs from Task 2 with these PUBLIC methods (above `private`).

    def start_sampler!(interval:)
      @sampler&.shutdown
      @sampler = Concurrent::TimerTask.new(execution_interval: interval) { sample! }
      @sampler.execute
      @sampler
    end

    # Unsubscribe from all events and shut down the sampler. Safe to call twice.
    def stop!
      @subscribers.each { |subscriber| ActiveSupport::Notifications.unsubscribe(subscriber) }
      @subscribers.clear
      @sampler&.shutdown
      @sampler = nil
    end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/unit/pool_observer_spec.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/apartment/pool_observer.rb spec/unit/pool_observer_spec.rb
git commit -m "PoolObserver: start_sampler! TimerTask + stop! teardown"
```

---

### Task 5: Error isolation — sink/sample failures never propagate

**Files:**
- Test: `spec/unit/pool_observer_spec.rb` (the rescues already exist from Tasks 2-3; this locks them with tests)

- [ ] **Step 1: Write the failing tests**

```ruby
# Add inside the RSpec.describe block.
  describe 'error isolation' do
    let(:boom_sink) { ->(_sample) { raise('sink boom') } }

    after { @observer&.stop! }

    it 'does not propagate when the sink raises on an event' do
      @observer = described_class.install!(sink: boom_sink)
      expect { Apartment::Instrumentation.instrument(:evict, {}) }.not_to(raise_error)
    end

    it 'does not propagate when the sink raises during sample!' do
      allow(Apartment).to(receive(:pool_manager)
        .and_return(instance_double(Apartment::PoolManager, stats: { total_pools: 1, tenants: [] })))
      @observer = described_class.new(sink: boom_sink)
      expect { @observer.sample! }.not_to(raise_error)
    end

    it 'does not propagate when backend_count raises' do
      allow(Apartment).to(receive(:pool_manager)
        .and_return(instance_double(Apartment::PoolManager, stats: { total_pools: 1, tenants: [] })))
      @observer = described_class.new(sink: sink, backend_count: -> { raise('backend boom') })
      expect { @observer.sample! }.not_to(raise_error)
    end
  end
```

- [ ] **Step 2: Run tests to verify they pass (rescues already present)**

Run: `bundle exec rspec spec/unit/pool_observer_spec.rb -e "error isolation"`
Expected: PASS (Tasks 2-3 already added the `rescue StandardError` guards; if any test fails, the corresponding guard is missing — add it before moving on)

- [ ] **Step 3: Commit**

```bash
git add spec/unit/pool_observer_spec.rb
git commit -m "PoolObserver: lock error isolation for sink and sample failures"
```

---

### Task 6: `docs/observability.md` — the event/stats contract

**Files:**
- Create: `docs/observability.md`
- Modify: `README.md` (add one link under an Observability/Pool section)
- Modify: `lib/apartment/CLAUDE.md` (add a `pool_observer.rb` file-guide entry)

- [ ] **Step 1: Write `docs/observability.md`**

Document, in this order:

1. **Event catalog** — a table of the seven `*.apartment` events and their payload fields:
   - `create` → `{ tenant: }`
   - `drop` → `{ tenant: }`
   - `evict` → `{ tenant:, reason: }` (`reason`: `:idle` / `:lru` / `:admission`)
   - `cap_unmet` → `{ max_total:, current:, unevicted: }`
   - `skip_evict` → `{ tenant:, reason:, eviction_reason:, busy_connections?, open_transactions? }`
   - `reaper_stopped` → `{ reason: }` (`:test_env`)
   - `migrate_tenant` → `{ tenant:, ... }`
   (Cross-check each against `lib/apartment/pool_reaper.rb` and the adapters before writing — payloads must match the source.)
2. **`PoolManager#stats`** — returns `{ total_pools:, tenants: }`; note monotonic-clock `stats_for(tenant_key)` → `{ seconds_idle: }`.
3. **`Apartment::PoolObserver` recipe** — the `install!` example, the `Sample` shape, the `sink`/`backend_count` seams, alerting in the sink (branch on `sample.name` for `:cap_unmet` / `:skip_evict`), and `stop!` for teardown.
4. A short "ships no transport" note: counters via events, gauges via the sampler; the adopter owns the metrics backend.

- [ ] **Step 2: Add a README pointer**

Add under the README's pool/observability area:

```markdown
### Observability

Apartment emits `ActiveSupport::Notifications` for the pool lifecycle and ships
`Apartment::PoolObserver`, a sink-agnostic subscriber + sampler. See
[docs/observability.md](docs/observability.md).
```

- [ ] **Step 3: Add the file-guide entry**

In `lib/apartment/CLAUDE.md`, add under the v4 files list:

```markdown
### pool_observer.rb — Observability (opt-in)

Sink-agnostic subscriber for the pool events (`create`/`evict`/`cap_unmet`/`skip_evict`/`reaper_stopped`) + an optional `Concurrent::TimerTask` gauge sampler (`tenant_pools_live`, optional adopter `backend_count`). Normalizes each to a `Sample` and forwards to a caller `sink`; ships no transport. Error-isolated — never raises into instrumentation. See `docs/observability.md`.
```

- [ ] **Step 4: Verify the doc links resolve and commit**

Run: `grep -n "docs/observability.md" README.md && test -f docs/observability.md && echo OK`
Expected: prints the README line and `OK`

```bash
git add docs/observability.md README.md lib/apartment/CLAUDE.md
git commit -m "Docs: observability guide (event catalog, PoolManager#stats, PoolObserver recipe)"
```

---

### Task 7: Verify — RuboCop + full unit suite + cross-version

**Files:** none (verification only)

- [ ] **Step 1: RuboCop on the new/changed files**

Run: `bundle exec rubocop lib/apartment/pool_observer.rb spec/unit/pool_observer_spec.rb`
Expected: `no offenses detected` (fix any inline; the class may need a `# rubocop:disable Metrics/...` only if genuinely over a threshold)

- [ ] **Step 2: Full unit suite**

Run: `bundle exec rspec spec/unit/`
Expected: all green, 0 failures (new `pool_observer_spec` examples included)

- [ ] **Step 3: Cross-version smoke (oldest + newest supported Rails)**

Run: `bundle exec appraisal rails-7.2-sqlite3 rspec spec/unit/pool_observer_spec.rb`
Run: `bundle exec appraisal rails-8.1-sqlite3 rspec spec/unit/pool_observer_spec.rb`
Expected: green on both (confirms `Data.define` + `ActiveSupport::Notifications` behavior across the matrix)

- [ ] **Step 4: Final commit (if any RuboCop fixes were needed)**

```bash
git add -A
git commit -m "PoolObserver: rubocop + cross-version green"
```

---

## Self-Review

**Spec coverage (component C + observability half of D):**
- Sink-agnostic subscribe → `Sample` → sink: Tasks 1-2. ✓
- Optional sampler (`tenant_pools_live` + optional `backend_count`): Tasks 3-4. ✓
- Error isolation (never raises into instrumentation): Tasks 2-3 (guards) + Task 5 (tests). ✓
- Lifecycle (`install!` / `stop!`): Tasks 2, 4. ✓
- `Sample` value object (name/kind/value/dimensions/payload): Task 1. ✓
- Observability docs (event catalog, stats, recipe): Task 6. ✓
- Out of scope (transport, DB-specific backend query): kept as `sink` / `backend_count` callables. ✓
- NOT in this PR (per the reordered sequence): `reap_in_test` (A), `Tenant.each(release_connection:)` + iteration table (B). Correct — those are PR 2 and PR 3.

**Placeholder scan:** Task 6 step 1 describes doc *content* rather than pasting final prose — acceptable for a docs task, but the executor must cross-check every payload field against source before writing (called out inline). No `TODO`/`TBD` in code steps.

**Type consistency:** `Sample.new(name:, kind:, value:, dimensions:, payload:)` is identical across Tasks 1-5. `COUNTER_EVENTS` (Task 2) matches the subscribed-events test (Task 2) and the file-guide entry (Task 6). `install!(sink:, sample_interval:, backend_count:)` and `sample!`/`start_sampler!(interval:)`/`stop!` signatures are consistent across tasks. The Task 2 temporary `stop!`/`start_sampler!` stubs are explicitly replaced in Task 4 (flagged inline) to avoid a dangling no-op.
