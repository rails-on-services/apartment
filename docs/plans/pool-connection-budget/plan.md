# Pool Connection Budget + Checkout-Pressure Observability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the tenant connection budget honest (two clear knobs replacing the misnamed `max_total_connections`), document the anti-starvation sizing rule, and surface checkout pressure as metrics.

**Architecture:** `Config` gains `max_tenant_pools` (pool-count cap) and `max_tenant_connections` (connection ceiling); `Config#effective_pool_budget` derives `min(max_tenant_pools, floor(max_tenant_connections / tenant_pool_size))` and is passed once to the `PoolReaper` at `Apartment.configure` time, so admission stays a pure pool-count check. `max_total_connections` is deprecated to an alias of `max_tenant_pools`. `PoolObserver#sample!` grows a checkout-pressure pass over each tenant pool's AR `ConnectionPool#stat`.

**Tech Stack:** Ruby (3.3/3.4/4.0), ActiveRecord (Rails 7.2/8.0/8.1), RSpec, `concurrent-ruby`.

**Design spec:** [docs/designs/pool-connection-budget.md](../../designs/pool-connection-budget.md)

## Global Constraints

- **OSS gem — no CampusESP or other private references** in code, tests, docs, or commit messages.
- **`max_total_connections` is deprecated, not removed** — it keeps working as an alias of `max_tenant_pools` and prints a deprecation warning; removal is scheduled for v5. Do not delete its existing validation.
- **`Apartment.config` is frozen after `configure`** — tests reconfigure via `Apartment.configure`; never stub the frozen config object.
- **RuboCop must pass on every changed Ruby file** (implementation and specs) before each commit: `bundle exec rubocop <files>`.
- **Run the unit suite** for each task: `bundle exec rspec spec/unit/`. No database is required for any task in this plan.
- **Every commit message ends with the two repo trailers** (`Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` and the `Claude-Session:` line). Commit subjects below show the first line only; append the trailers.
- **Global pool size assumption:** every tenant pool is sized to `tenant_pool_size`; the derived budget relies on this uniformity.

## File Structure

- `lib/apartment/config.rb` — new accessors, defaults, validations, deprecation alias, `effective_pool_budget`.
- `lib/apartment.rb` — `setup_pools!` reads `effective_pool_budget` instead of `max_total_connections`.
- `lib/apartment/pool_observer.rb` — `sample!` emits checkout-pressure gauges.
- `lib/apartment/pool_reaper.rb` — **unchanged** (receives the derived budget via its existing `max_total:` argument).
- `spec/unit/config_spec.rb` — Tasks 1–3 tests.
- `spec/unit/apartment_spec.rb` — Task 4 wiring test.
- `spec/unit/pool_observer_spec.rb` — Task 5 tests.
- Docs (Task 6): `README.md`, `docs/designs/pool-admission-control.md`, `docs/upgrading-to-v4.md`, `docs/observability.md`, `docs/designs/v4-connection-model-rationale.md`, `lib/apartment/CLAUDE.md`, `lib/generators/apartment/install/templates/apartment.rb`.

---

### Task 1: Config knobs `max_tenant_pools` + `max_tenant_connections` (accessors, defaults, type validation)

**Files:**
- Modify: `lib/apartment/config.rb`
- Test: `spec/unit/config_spec.rb`

**Interfaces:**
- Produces: `Config#max_tenant_pools`, `Config#max_tenant_pools=`, `Config#max_tenant_connections`, `Config#max_tenant_connections=` (each `Integer | nil`, default `nil`).

- [ ] **Step 1: Write the failing tests**

Add to `spec/unit/config_spec.rb`. Put the two default expectations alongside the existing `tenant_pool_size` / `max_total_connections` default examples (near line 13), and the two validation examples in the `validate!` group (near line 180):

```ruby
    # defaults group (near the existing `max_total_connections` default at ~line 16)
    it { expect(config.max_tenant_pools).to(be_nil) }
    it { expect(config.max_tenant_connections).to(be_nil) }
```

```ruby
    # validate! group (near the existing `max_total_connections` invalid case at ~line 180)
    it 'raises when max_tenant_pools is not a positive integer' do
      config.tenant_strategy = :schema
      config.tenants_provider = -> { [] }
      config.max_tenant_pools = 0
      expect { config.validate! }.to(raise_error(Apartment::ConfigurationError, /max_tenant_pools/))
    end

    it 'raises when max_tenant_connections is not a positive integer' do
      config.tenant_strategy = :schema
      config.tenants_provider = -> { [] }
      config.max_tenant_connections = 0
      expect { config.validate! }.to(raise_error(Apartment::ConfigurationError, /max_tenant_connections/))
    end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec rspec spec/unit/config_spec.rb -e max_tenant`
Expected: FAIL (`NoMethodError: undefined method 'max_tenant_pools='` and the two default examples failing).

- [ ] **Step 3: Add the accessors and defaults**

In `lib/apartment/config.rb`, extend the `attr_accessor` list — insert after the existing `:max_total_connections,` entry (currently on the line with `:pool_overflow_policy`):

```ruby
                  :max_total_connections, :max_tenant_pools, :max_tenant_connections,
                  :pool_overflow_policy,
```

In `initialize`, immediately after `@max_total_connections = nil`, add:

```ruby
      @max_tenant_pools = nil
      @max_tenant_connections = nil
```

- [ ] **Step 4: Add the type validations**

In `validate!`, immediately after the existing `max_total_connections` block (the one raising `"max_total_connections must be a positive integer or nil..."`), add:

```ruby
      if @max_tenant_pools && (!@max_tenant_pools.is_a?(Integer) || @max_tenant_pools < 1)
        raise(ConfigurationError,
              "max_tenant_pools must be a positive integer or nil, got: #{@max_tenant_pools.inspect}")
      end

      if @max_tenant_connections && (!@max_tenant_connections.is_a?(Integer) || @max_tenant_connections < 1)
        raise(ConfigurationError,
              "max_tenant_connections must be a positive integer or nil, got: #{@max_tenant_connections.inspect}")
      end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bundle exec rspec spec/unit/config_spec.rb -e max_tenant`
Expected: PASS.

- [ ] **Step 6: RuboCop + full unit suite**

Run: `bundle exec rubocop lib/apartment/config.rb spec/unit/config_spec.rb && bundle exec rspec spec/unit/`
Expected: no offenses; all examples pass.

- [ ] **Step 7: Commit**

```bash
git add lib/apartment/config.rb spec/unit/config_spec.rb
git commit -m "Feat(v4): add max_tenant_pools + max_tenant_connections config knobs"
```

---

### Task 2: `Config#effective_pool_budget` + derive validations

**Files:**
- Modify: `lib/apartment/config.rb`
- Test: `spec/unit/config_spec.rb`

**Interfaces:**
- Consumes: `max_tenant_pools`, `max_tenant_connections`, `tenant_pool_size` (Task 1 + existing).
- Produces: `Config#effective_pool_budget` → `Integer | nil` — the pool-count bound admission enforces; `nil` when neither knob is set.

- [ ] **Step 1: Write the failing tests**

Add a new describe block to `spec/unit/config_spec.rb` (top level, after the `validate!` group):

```ruby
  describe '#effective_pool_budget' do
    it 'returns nil when neither knob is set' do
      expect(config.effective_pool_budget).to(be_nil)
    end

    it 'returns max_tenant_pools when only it is set' do
      config.max_tenant_pools = 8
      expect(config.effective_pool_budget).to(eq(8))
    end

    it 'derives the pool budget from the connection ceiling with floor division' do
      config.tenant_pool_size = 3
      config.max_tenant_connections = 20
      expect(config.effective_pool_budget).to(eq(6)) # floor(20 / 3)
    end

    it 'takes the stricter of the explicit pool cap and the derived budget' do
      config.tenant_pool_size = 2
      config.max_tenant_connections = 20 # -> 10 pools
      config.max_tenant_pools = 4
      expect(config.effective_pool_budget).to(eq(4))
    end
  end
```

And two validation examples in the `validate!` group:

```ruby
    it 'raises when max_tenant_connections is set without tenant_pool_size' do
      config.tenant_strategy = :schema
      config.tenants_provider = -> { [] }
      config.tenant_pool_size = nil
      config.max_tenant_connections = 10
      expect { config.validate! }.to(raise_error(Apartment::ConfigurationError, /tenant_pool_size/))
    end

    it 'raises when max_tenant_connections is below tenant_pool_size' do
      config.tenant_strategy = :schema
      config.tenants_provider = -> { [] }
      config.tenant_pool_size = 5
      config.max_tenant_connections = 3
      expect { config.validate! }.to(raise_error(Apartment::ConfigurationError, /tenant_pool_size/))
    end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec rspec spec/unit/config_spec.rb -e effective_pool_budget -e "max_tenant_connections is"`
Expected: FAIL (`NoMethodError: undefined method 'effective_pool_budget'`; the two validations do not yet raise).

- [ ] **Step 3: Add the `effective_pool_budget` method**

In `lib/apartment/config.rb`, add a public method (e.g. directly after `rails_env_name`):

```ruby
    # The pool-count bound the admission controller enforces: the stricter of the
    # explicit pool cap (max_tenant_pools) and the pool budget derived from the
    # connection ceiling (max_tenant_connections / tenant_pool_size, floored).
    # Returns nil (uncapped) when neither knob is set. Relies on a global
    # tenant_pool_size, so tenant-pool connections <= budget * tenant_pool_size.
    def effective_pool_budget
      derived = @max_tenant_connections && @tenant_pool_size ? @max_tenant_connections / @tenant_pool_size : nil
      [@max_tenant_pools, derived].compact.min
    end
```

- [ ] **Step 4: Add the derive validations**

In `validate!`, after the Task 1 `max_tenant_connections` type check, add:

```ruby
      if @max_tenant_connections && @tenant_pool_size.nil?
        raise(ConfigurationError,
              'max_tenant_connections requires tenant_pool_size to be set (the pool budget is ' \
              'derived as max_tenant_connections / tenant_pool_size)')
      end

      if @max_tenant_connections && @tenant_pool_size && @max_tenant_connections < @tenant_pool_size
        raise(ConfigurationError,
              "max_tenant_connections (#{@max_tenant_connections}) must be >= tenant_pool_size " \
              "(#{@tenant_pool_size}); it cannot fit a single tenant pool")
      end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bundle exec rspec spec/unit/config_spec.rb -e effective_pool_budget -e "max_tenant_connections is"`
Expected: PASS.

- [ ] **Step 6: RuboCop + full unit suite**

Run: `bundle exec rubocop lib/apartment/config.rb spec/unit/config_spec.rb && bundle exec rspec spec/unit/`
Expected: no offenses; all pass.

- [ ] **Step 7: Commit**

```bash
git add lib/apartment/config.rb spec/unit/config_spec.rb
git commit -m "Feat(v4): derive effective_pool_budget from the connection ceiling"
```

---

### Task 3: Deprecate `max_total_connections` → alias of `max_tenant_pools`

**Files:**
- Modify: `lib/apartment/config.rb`
- Test: `spec/unit/config_spec.rb`

**Interfaces:**
- Consumes: `max_total_connections` (existing), `max_tenant_pools` (Task 1).
- Behavior: `apply_defaults!` warns once and sets `max_tenant_pools ||= max_total_connections`; `validate!` raises when both are explicitly set to unequal values.

- [ ] **Step 1: Write the failing tests**

Add to `spec/unit/config_spec.rb`:

```ruby
  describe 'max_total_connections deprecation' do
    it 'warns and aliases max_total_connections to max_tenant_pools' do
      config.max_total_connections = 8
      expect { config.apply_defaults! }.to(output(/DEPRECATION.*max_total_connections/).to_stderr)
      expect(config.max_tenant_pools).to(eq(8))
    end

    it 'does not overwrite an explicitly set max_tenant_pools' do
      config.max_total_connections = 8
      config.max_tenant_pools = 8
      config.apply_defaults!
      expect(config.max_tenant_pools).to(eq(8))
    end

    it 'raises when max_total_connections and max_tenant_pools disagree' do
      config.tenant_strategy = :schema
      config.tenants_provider = -> { [] }
      config.max_total_connections = 8
      config.max_tenant_pools = 4
      expect { config.validate! }.to(raise_error(Apartment::ConfigurationError, /max_total_connections/))
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec rspec spec/unit/config_spec.rb -e "max_total_connections deprecation"`
Expected: FAIL (no warning emitted; alias not applied; no raise on disagreement).

- [ ] **Step 3: Add the deprecation alias to `apply_defaults!`**

In `lib/apartment/config.rb`, inside `apply_defaults!`, add (after the existing `reaper_interval` default line):

```ruby
      # max_total_connections is deprecated: the name said "connections" but it
      # always capped tenant-pool COUNT. Alias it to its true meaning without
      # changing behavior. Only fill when max_tenant_pools was not set explicitly,
      # so validate!'s both-set guard can still catch a genuine double-spec.
      if @max_total_connections
        warn '[Apartment] DEPRECATION: config.max_total_connections is deprecated and will be ' \
             'removed in v5. It caps tenant-pool COUNT, not connections; rename it to ' \
             'max_tenant_pools. For a true connection ceiling, set max_tenant_connections.'
        @max_tenant_pools = @max_total_connections if @max_tenant_pools.nil?
      end
```

- [ ] **Step 4: Add the both-set guard to `validate!`**

In `validate!`, after the `max_tenant_pools` type check, add:

```ruby
      if @max_total_connections && @max_tenant_pools && @max_total_connections != @max_tenant_pools
        raise(ConfigurationError,
              'max_total_connections and max_tenant_pools are the same setting under two names; ' \
              "set only one. Got max_total_connections=#{@max_total_connections}, " \
              "max_tenant_pools=#{@max_tenant_pools}")
      end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bundle exec rspec spec/unit/config_spec.rb -e "max_total_connections deprecation"`
Expected: PASS.

- [ ] **Step 6: RuboCop + full unit suite**

Run: `bundle exec rubocop lib/apartment/config.rb spec/unit/config_spec.rb && bundle exec rspec spec/unit/`
Expected: no offenses; all pass. (The existing `max_total_connections = 0` validation example still passes — it is unchanged.)

- [ ] **Step 7: Commit**

```bash
git add lib/apartment/config.rb spec/unit/config_spec.rb
git commit -m "Feat(v4): deprecate max_total_connections as an alias of max_tenant_pools"
```

---

### Task 4: Wire `effective_pool_budget` into the reaper

**Files:**
- Modify: `lib/apartment.rb` (`setup_pools!`, currently lines ~271-284)
- Test: `spec/unit/apartment_spec.rb`

**Interfaces:**
- Consumes: `Config#effective_pool_budget` (Task 2).
- Behavior: the reaper receives the derived budget as `max_total:`; the admission controller is wired iff `effective_pool_budget` is non-nil. `PoolReaper` is unchanged.

- [ ] **Step 1: Write the failing test**

Add to `spec/unit/apartment_spec.rb`, in the same group as the existing admission-wiring examples (near line 317, which end with `after { described_class.clear_config }`):

```ruby
    it 'wires admission from a derived connection ceiling (max_tenant_connections)' do
      described_class.configure do |config|
        config.tenant_strategy = :schema
        config.tenants_provider = -> { [] }
        config.tenant_pool_size = 2
        config.max_tenant_connections = 10 # -> floor(10/2) = 5 pools
      end
      expect(described_class.pool_manager.admission_controller).to(eq(described_class.pool_reaper))
    end

    it 'leaves the pool manager uncapped when no budget knob is set' do
      described_class.configure do |config|
        config.tenant_strategy = :schema
        config.tenants_provider = -> { [] }
      end
      expect(described_class.pool_manager.admission_controller).to(be_nil)
    end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bundle exec rspec spec/unit/apartment_spec.rb -e "derived connection ceiling"`
Expected: FAIL (admission controller is `nil` because `setup_pools!` still reads `max_total_connections`, which is unset here).

- [ ] **Step 3: Update `setup_pools!`**

In `lib/apartment.rb`, change the `max_total:` argument and the admission-controller guard to read the derived budget:

```ruby
      budget = new_config.effective_pool_budget
      @pool_manager = PoolManager.new
      @pool_reaper = PoolReaper.new(
        pool_manager: @pool_manager,
        interval: new_config.reaper_interval,
        idle_timeout: new_config.pool_idle_timeout,
        max_total: budget,
        default_tenant: new_config.default_tenant,
        shard_key_prefix: new_config.shard_key_prefix,
        overflow_policy: new_config.pool_overflow_policy
      )
      @pool_manager.admission_controller = @pool_reaper if budget
      @pool_reaper.start
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bundle exec rspec spec/unit/apartment_spec.rb -e "derived connection ceiling" -e "uncapped when no budget"`
Expected: PASS.

- [ ] **Step 5: RuboCop + full unit suite**

Run: `bundle exec rubocop lib/apartment.rb spec/unit/apartment_spec.rb && bundle exec rspec spec/unit/`
Expected: no offenses; all pass. (The existing `max_total_connections = 5` wiring example still passes via the deprecation alias.)

- [ ] **Step 6: Commit**

```bash
git add lib/apartment.rb spec/unit/apartment_spec.rb
git commit -m "Feat(v4): admission control enforces the derived effective_pool_budget"
```

---

### Task 5: Checkout-pressure gauges in `PoolObserver#sample!`

**Files:**
- Modify: `lib/apartment/pool_observer.rb`
- Test: `spec/unit/pool_observer_spec.rb`

**Interfaces:**
- Consumes: `Apartment.pool_manager.each_pair { |tenant_key, pool| ... }` (existing) and each pool's AR `ConnectionPool#stat` (`{ size:, busy:, waiting:, ... }`).
- Produces three additional gauges per `sample!` pass: `pools_waiting`, `pools_saturated`, `max_checkout_waiting` (tenant key in the Sample `payload`, not `dimensions`).

- [ ] **Step 1: Write the failing tests**

Add to `spec/unit/pool_observer_spec.rb`:

```ruby
  describe '#sample! checkout pressure' do
    def fake_pool(size:, busy:, waiting:)
      instance_double(ActiveRecord::ConnectionAdapters::ConnectionPool,
                      stat: { size: size, busy: busy, waiting: waiting })
    end

    let(:pools) do
      {
        'acme:writing' => fake_pool(size: 2, busy: 2, waiting: 3),
        'beta:writing' => fake_pool(size: 5, busy: 1, waiting: 0),
      }
    end

    let(:stub_manager) { instance_double(Apartment::PoolManager, stats: { total_pools: 2, tenants: [] }) }

    before do
      allow(Apartment).to(receive(:pool_manager).and_return(stub_manager))
      allow(stub_manager).to(receive(:each_pair)) { |&blk| pools.each(&blk) }
    end

    it 'counts pools with threads waiting on checkout' do
      described_class.new(sink: sink).sample!
      expect(samples.find { |s| s.name == :pools_waiting }.value).to(eq(1))
    end

    it 'counts saturated pools where busy >= size' do
      described_class.new(sink: sink).sample!
      expect(samples.find { |s| s.name == :pools_saturated }.value).to(eq(1))
    end

    it 'reports the worst waiting count with the tenant in payload, not dimensions' do
      described_class.new(sink: sink).sample!
      sample = samples.find { |s| s.name == :max_checkout_waiting }
      expect(sample).to(have_attributes(kind: :gauge, value: 3, dimensions: {}, payload: { tenant: 'acme:writing' }))
    end

    it 'skips a pool whose #stat raises without breaking the pass' do
      broken = instance_double(ActiveRecord::ConnectionAdapters::ConnectionPool)
      allow(broken).to(receive(:stat).and_raise(StandardError, 'pool tearing down'))
      pools['broken:writing'] = broken
      described_class.new(sink: sink).sample!
      expect(samples.map(&:name)).to(include(:pools_waiting, :pools_saturated, :max_checkout_waiting))
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec rspec spec/unit/pool_observer_spec.rb -e "checkout pressure"`
Expected: FAIL (no `pools_waiting` / `pools_saturated` / `max_checkout_waiting` samples emitted).

- [ ] **Step 3: Emit the gauges from `sample!`**

In `lib/apartment/pool_observer.rb`, call a new private method at the end of `sample!`'s body — insert immediately before the `rescue StandardError => e` line:

```ruby
      emit_checkout_pressure!
```

Then add the private method (e.g. after `sample!`):

```ruby
    # Per-tenant-pool checkout pressure, aggregated to low cardinality. waiting>0
    # means threads are blocked acquiring a connection (the same-tenant fan-out
    # starvation signal). The worst tenant is carried in payload, NOT as a metric
    # dimension, to avoid unbounded time-series churn. Per-pool #stat is rescued
    # so a pool tearing down mid-sample can't abort the whole pass.
    def emit_checkout_pressure!
      manager = Apartment.pool_manager
      return unless manager

      waiting = 0
      saturated = 0
      max_wait = 0
      max_wait_tenant = nil

      manager.each_pair do |tenant_key, pool|
        stat = pool.stat
        pending = stat[:waiting].to_i
        waiting += 1 if pending.positive?
        saturated += 1 if stat[:busy].to_i >= stat[:size].to_i
        if pending > max_wait
          max_wait = pending
          max_wait_tenant = tenant_key
        end
      rescue StandardError
        next # a pool mid-teardown can raise; skip it, keep the pass
      end

      emit(Sample.new(name: :pools_waiting, kind: :gauge, value: waiting, dimensions: {}, payload: {}))
      emit(Sample.new(name: :pools_saturated, kind: :gauge, value: saturated, dimensions: {}, payload: {}))
      emit(Sample.new(name: :max_checkout_waiting, kind: :gauge, value: max_wait,
                      dimensions: {}, payload: max_wait_tenant ? { tenant: max_wait_tenant } : {}))
    end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bundle exec rspec spec/unit/pool_observer_spec.rb -e "checkout pressure"`
Expected: PASS.

- [ ] **Step 5: RuboCop + full unit suite**

Run: `bundle exec rubocop lib/apartment/pool_observer.rb spec/unit/pool_observer_spec.rb && bundle exec rspec spec/unit/`
Expected: no offenses; all pass. (The existing `sample!` examples that stub `pool_manager` without `each_pair` still pass — those stubs return a manager whose `each_pair` is unstubbed only where the new group adds it; if an existing example fails because `each_pair` is now called, stub it to yield nothing: `allow(stub_manager).to(receive(:each_pair))`.)

- [ ] **Step 6: Commit**

```bash
git add lib/apartment/pool_observer.rb spec/unit/pool_observer_spec.rb
git commit -m "Feat(v4): emit checkout-pressure gauges from PoolObserver#sample!"
```

---

### Task 6: Documentation (Item 2)

**Files:**
- Modify: `README.md`, `docs/designs/pool-admission-control.md`, `docs/upgrading-to-v4.md`, `docs/observability.md`, `docs/designs/v4-connection-model-rationale.md`, `lib/apartment/CLAUDE.md`, `lib/generators/apartment/install/templates/apartment.rb`

**Interfaces:** none (documentation + a generator template comment).

- [ ] **Step 1: README + generator template — the knobs and the sizing rule**

In `README.md` (config-options section) and the generator template `lib/generators/apartment/install/templates/apartment.rb`, replace `max_total_connections` guidance with the two knobs and add the sizing rule. Template comment to add near the pool settings:

```ruby
  # Pool sizing (v4). tenant_pool_size MUST be >= the peak number of threads/fibers
  # in one process that can touch the SAME tenant at once (e.g. a Sidekiq role's
  # concurrency for a same-tenant job fan-out); otherwise those threads block on
  # connection checkout. tenant_pool_size is a lazy ceiling — connections are
  # created on demand and idle pools are reaped, so it does not hold that many
  # connections open at steady state.
  # config.tenant_pool_size = 5
  #
  # Bound how many tenant pools exist per process:
  # config.max_tenant_pools = 50
  # ...or bound total tenant-pool CONNECTIONS (requires tenant_pool_size); the
  # admission controller derives the pool budget as floor(value / tenant_pool_size):
  # config.max_tenant_connections = 250
  #
  # max_total_connections is DEPRECATED (alias of max_tenant_pools; removed in v5).
```

- [ ] **Step 2: The true ceiling formula + worked example**

Add to `README.md` and `docs/designs/v4-connection-model-rationale.md`:

```
Per-process tenant-pool connections <= effective_pool_budget * tenant_pool_size
where effective_pool_budget = min(max_tenant_pools, floor(max_tenant_connections / tenant_pool_size))
Total process connections ~= (effective_pool_budget * tenant_pool_size) + default_pool + pinned_pool

Worked example: tenant_pool_size=5, max_tenant_connections=250
  -> effective_pool_budget = floor(250/5) = 50 pools
  -> up to 250 tenant-pool connections, + the default pool + any separate pinned pool.
A tenant using writing+reading roles holds TWO pools ("tenant:role" keys), so it
counts twice against max_tenant_pools and halves how many tenants fit in the budget.
For a hard external-pooler budget, pair max_tenant_connections with
pool_overflow_policy: :raise (the ceiling is soft under the default :evict_idle).
```

- [ ] **Step 3: Upgrading guide — the deprecation**

Add a section to `docs/upgrading-to-v4.md`:

```markdown
### `max_total_connections` renamed

`max_total_connections` always capped tenant-pool **count**, not connections. It is
deprecated (removed in v5) and now aliases `max_tenant_pools`; rename it. For a true
connection ceiling, set `max_tenant_connections` (requires `tenant_pool_size`); the
admission controller derives the pool budget as
`floor(max_tenant_connections / tenant_pool_size)`.
```

- [ ] **Step 4: Observability doc — the new gauges and sampling guidance**

Add to `docs/observability.md`: document `pools_waiting`, `pools_saturated`, and `max_checkout_waiting` (tenant in `payload`, opt-in as a high-cardinality dimension). Add the sampling note:

```markdown
Checkout-pressure gauges are sampled instantaneously (not peak-held), so a short
starvation episode can fall between samples. Use a short `sample_interval` (5-10s)
on Sidekiq/job roles to catch sustained same-tenant fan-out; the gauges show
pressure, not lossless timeout accounting (standard APM captures the
`ConnectionTimeoutError` itself).
```

- [ ] **Step 5: Cross-reference docs — admission-control design + implementation guide**

- In `docs/designs/pool-admission-control.md`, add a note that the cap knob is now `max_tenant_pools` (with `max_total_connections` deprecated) and that the enforced bound is `Config#effective_pool_budget`; link to `docs/designs/pool-connection-budget.md`.
- In `lib/apartment/CLAUDE.md`, update the `config.rb` and `pool_manager.rb` / `pool_reaper.rb` entries to mention `max_tenant_pools` / `max_tenant_connections` / `effective_pool_budget` and the new `pool_observer.rb` gauges.

- [ ] **Step 6: RuboCop the template + verify references**

Run: `bundle exec rubocop lib/generators/apartment/install/templates/apartment.rb`
Run: `grep -rn "max_tenant_pools\|max_tenant_connections\|effective_pool_budget" README.md docs/ lib/apartment/CLAUDE.md`
Expected: no offenses; the new names appear in every doc touched above; no lingering claim that `max_total_connections` bounds connections.

- [ ] **Step 7: Commit**

```bash
git add README.md docs/ lib/apartment/CLAUDE.md lib/generators/apartment/install/templates/apartment.rb
git commit -m "Docs(v4): document the connection-budget knobs, ceiling formula, and checkout gauges"
```

---

## Self-Review

**Spec coverage:**

- Item 1 — three keys → Tasks 1 (new knobs), 3 (deprecated alias); `derive + min` → Task 2; derivation in `configure` → Task 4; all five validations → Tasks 1–3; honesty scope (`tenant:role`, default/pinned, soft cap) → Task 6 docs. ✅
- Item 2 — sizing rule, ceiling formula, lazy-ceiling note, `:raise` pairing, role multiplier, doc locations → Task 6. ✅
- Item 3 — `pools_waiting` / `pools_saturated` / `max_checkout_waiting`, tenant-in-payload, error isolation, sampling honesty → Task 5 (code) + Task 6 (sampling docs). Deferred checkout-timeout event → intentionally not implemented. ✅
- Testing section of spec — config/derivation/validation/deprecation → Tasks 1–3; admission wiring → Task 4; observability incl. raising `#stat` → Task 5. ✅

**Placeholder scan:** every code step shows the exact code; every command shows the exact invocation and expected result. No TBD/TODO. ✅

**Type consistency:** `effective_pool_budget` (defined Task 2) is consumed with that exact name in Task 4; `max_tenant_pools` / `max_tenant_connections` accessor names are consistent across Tasks 1–4 and Task 6; gauge names `pools_waiting` / `pools_saturated` / `max_checkout_waiting` match between Task 5 code and tests and Task 6 docs. ✅

## Phasing

- **PR 1 (Item 1 + Item 2):** Tasks 1–4 (knobs, budget, deprecation, wiring) + Task 6 (docs describe those knobs).
- **PR 2 (Item 3):** Task 5 (observability), independent of the config changes.
