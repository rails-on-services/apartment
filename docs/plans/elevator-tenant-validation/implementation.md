# Elevator Tenant Validation & Not-Found Handling — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make apartment's elevators validate a resolved tenant name before switching, so an unknown subdomain returns a clean 404 instead of an opaque 500 from a non-existent schema.

**Architecture:** Two pluggable seams in `Generic#call` — `config.tenant_validator` (name → bool) and `config.tenant_not_found_handler` (`(tenant, request)` → Rack response). A built-in in-process `TenantValidator` runs on by default: a memoized `Set` of valid names, rate-limited single-flight rebuild-on-miss, TTL backstop, lifecycle invalidation via `create.apartment`/`drop.apartment` notifications, fail-open on source error. The railtie maps `Apartment::TenantNotFound` to `:not_found` so an unconfigured app still renders its own 404.

**Tech Stack:** Ruby, Rails (Railtie, ActionDispatch, ActiveSupport::Notifications), `concurrent-ruby`, RSpec.

**Spec:** `docs/designs/elevator-tenant-validation.md`

---

## File Structure

| File | Responsibility | Action |
|---|---|---|
| `lib/apartment/config.rb` | `tenant_validator` accessor + validation of both hooks | Modify |
| `lib/apartment/tenant_validator.rb` | The built-in in-process validator | Create |
| `lib/apartment.rb` | `Apartment.tenant_validator` resolver; built-in teardown on `clear_config`/`configure` | Modify |
| `lib/apartment/elevators/generic.rb` | Validate before switch; route not-found through the handler | Modify |
| `lib/apartment/railtie.rb` | Register `rescue_responses['Apartment::TenantNotFound'] = :not_found` | Modify |
| `lib/apartment.rb` (require) | `require 'apartment/tenant_validator'` | Modify |
| `docs/designs/v4-elevators.md`, `docs/designs/apartment-v4.md` | Resolve the elevator-vs-adapter contradiction | Modify |
| `CHANGELOG.md` | Breaking-change entry | Modify |
| `spec/unit/config_spec.rb` | Config accessor/validation specs | Modify |
| `spec/unit/tenant_validator_spec.rb` | `TenantValidator` specs | Create |
| `spec/unit/elevators/generic_spec.rb` | `Generic#call` validation specs | Modify |
| `spec/unit/railtie_spec.rb` | `rescue_responses` registration spec | Modify |
| `spec/integration/v4/request_lifecycle_spec.rb` | Unknown-subdomain → 404 integration spec | Modify |

Build order: Config → TenantValidator → resolver → Generic → railtie → docs → integration.

---

## Task 1: Config — `tenant_validator` accessor and hook validation

**Files:**
- Modify: `lib/apartment/config.rb`
- Test: `spec/unit/config_spec.rb`

- [ ] **Step 1: Write the failing tests**

Add to `spec/unit/config_spec.rb` (inside the top-level `RSpec.describe(Apartment::Config)` block):

```ruby
describe '#tenant_validator' do
  it 'defaults to nil' do
    expect(Apartment::Config.new.tenant_validator).to(be_nil)
  end

  it 'accepts false (validation disabled)' do
    config = Apartment::Config.new
    config.tenant_strategy = :schema
    config.tenants_provider = -> { [] }
    config.tenant_validator = false
    expect { config.validate! }.not_to(raise_error)
  end

  it 'accepts a callable' do
    config = Apartment::Config.new
    config.tenant_strategy = :schema
    config.tenants_provider = -> { [] }
    config.tenant_validator = ->(name) { name == 'acme' }
    expect { config.validate! }.not_to(raise_error)
  end

  it 'rejects a non-callable, non-false value' do
    config = Apartment::Config.new
    config.tenant_strategy = :schema
    config.tenants_provider = -> { [] }
    config.tenant_validator = 'nope'
    expect { config.validate! }
      .to(raise_error(Apartment::ConfigurationError, /tenant_validator/))
  end
end

describe '#tenant_not_found_handler' do
  it 'rejects a non-callable value' do
    config = Apartment::Config.new
    config.tenant_strategy = :schema
    config.tenants_provider = -> { [] }
    config.tenant_not_found_handler = 'nope'
    expect { config.validate! }
      .to(raise_error(Apartment::ConfigurationError, /tenant_not_found_handler/))
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec rspec spec/unit/config_spec.rb -e tenant_validator -e tenant_not_found_handler`
Expected: FAIL — `tenant_validator` is not a method; the validation specs do not raise.

- [ ] **Step 3: Add the accessor and default**

In `lib/apartment/config.rb`, add `:tenant_validator` to the `attr_accessor` list (alongside `:tenant_not_found_handler` on line 24):

```ruby
                  :tenant_not_found_handler, :tenant_validator,
                  :active_record_log, :sql_query_tags,
```

In `initialize`, after `@tenant_not_found_handler = nil` (line 46):

```ruby
      @tenant_not_found_handler = nil
      @tenant_validator = nil
```

- [ ] **Step 4: Add the validation**

In `lib/apartment/config.rb`, in `validate!`, before the final `return if @shard_key_prefix...` block:

```ruby
      unless @tenant_validator.nil? || @tenant_validator == false || @tenant_validator.respond_to?(:call)
        raise(ConfigurationError,
              'tenant_validator must be nil, false, or a callable, ' \
              "got: #{@tenant_validator.inspect}")
      end

      if @tenant_not_found_handler && !@tenant_not_found_handler.respond_to?(:call)
        raise(ConfigurationError,
              'tenant_not_found_handler must be nil or a callable, ' \
              "got: #{@tenant_not_found_handler.inspect}")
      end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bundle exec rspec spec/unit/config_spec.rb`
Expected: PASS, all examples green.

- [ ] **Step 6: Commit**

```bash
git add lib/apartment/config.rb spec/unit/config_spec.rb
git commit -m "Add Config#tenant_validator; validate both elevator hooks"
```

---

## Task 2: `TenantValidator` — core (positive set, rebuild-on-miss, TTL)

**Files:**
- Create: `lib/apartment/tenant_validator.rb`
- Test: `spec/unit/tenant_validator_spec.rb`

The validator reads tenant names from `Apartment.config.tenants_provider`. Specs configure Apartment with a provider they control.

- [ ] **Step 1: Write the failing tests**

Create `spec/unit/tenant_validator_spec.rb`:

```ruby
# frozen_string_literal: true

require 'spec_helper'
require 'apartment/tenant_validator'

RSpec.describe(Apartment::TenantValidator) do
  # Track validators built per example so notification subscriptions (added in
  # Task 3) are torn down. The respond_to? guard keeps this forward-compatible:
  # #shutdown does not exist until Task 3.
  def build_validator(**opts)
    validator = described_class.new(**opts)
    (@built_validators ||= []) << validator
    validator
  end

  after do
    (@built_validators || []).each { |v| v.shutdown if v.respond_to?(:shutdown) }
  end

  def configure(provider)
    Apartment.configure do |c|
      c.tenant_strategy = :schema
      c.default_tenant = 'public'
      c.tenants_provider = provider
    end
  end

  describe '#call' do
    it 'returns true for a name the provider lists' do
      configure(-> { %w[acme widgets] })
      expect(build_validator.call('acme')).to(be(true))
    end

    it 'returns false for a name the provider does not list' do
      configure(-> { %w[acme widgets] })
      expect(build_validator.call('ghost')).to(be(false))
    end

    it 'does not call the provider on every request (memoizes)' do
      calls = 0
      configure(-> { calls += 1; %w[acme] })
      validator = build_validator
      5.times { validator.call('acme') }
      expect(calls).to(eq(1))
    end

    it 'heals on a miss: a name added to the source becomes valid after a rebuild' do
      names = %w[acme]
      configure(-> { names })
      validator = build_validator(rebuild_interval: 0)
      expect(validator.call('widgets')).to(be(false))
      names << 'widgets'
      expect(validator.call('widgets')).to(be(true))
    end

    it 'rate-limits rebuilds: repeated misses inside the interval hit the source once' do
      calls = 0
      configure(-> { calls += 1; %w[acme] })
      validator = build_validator(rebuild_interval: 3600)
      10.times { validator.call('ghost') }
      expect(calls).to(eq(1)) # one lazy build; further misses are rate-limited
    end

    it 'rebuilds after the positive-set TTL' do
      names = %w[acme]
      configure(-> { names })
      validator = build_validator(positive_ttl: 0)
      expect(validator.call('acme')).to(be(true))
      names.replace(%w[widgets])
      expect(validator.call('acme')).to(be(false))
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec rspec spec/unit/tenant_validator_spec.rb`
Expected: FAIL — `cannot load such file -- apartment/tenant_validator`.

- [ ] **Step 3: Create the validator (core only)**

Create `lib/apartment/tenant_validator.rb`:

```ruby
# frozen_string_literal: true

require 'set'
require 'concurrent'

module Apartment
  # In-process, memoized validator: answers "is this a real tenant name?".
  # The positive set is sourced from config.tenants_provider, refreshed on a
  # TTL and — rate-limited, single-flight — on a miss. Lifecycle invalidation
  # and fail-open behavior are added in a later task.
  class TenantValidator
    DEFAULT_POSITIVE_TTL_SECONDS = 300
    DEFAULT_REBUILD_INTERVAL_SECONDS = 5

    def initialize(positive_ttl: DEFAULT_POSITIVE_TTL_SECONDS,
                   rebuild_interval: DEFAULT_REBUILD_INTERVAL_SECONDS)
      @positive_ttl = positive_ttl
      @rebuild_interval = rebuild_interval
      @names = Concurrent::Set.new
      @mutex = Mutex.new
      @built_at = nil
      @last_rebuild_at = nil
    end

    # @return [Boolean] whether `name` is a known tenant.
    def call(name)
      name = name.to_s
      rebuild if @built_at.nil? || stale?
      return true if @names.include?(name)

      rebuild_on_miss
      @names.include?(name)
    end
    alias valid? call

    private

    def stale?
      @built_at && (monotonic - @built_at) > @positive_ttl
    end

    def rebuild_on_miss
      return if @last_rebuild_at && (monotonic - @last_rebuild_at) < @rebuild_interval

      rebuild
    end

    # Single-flight: one thread rebuilds at a time; others skip and use the
    # current set, rechecking on their next request.
    def rebuild
      return unless @mutex.try_lock

      begin
        @last_rebuild_at = monotonic
        names = Array(Apartment.config.tenants_provider.call).map(&:to_s)
        @names = Concurrent::Set.new(names)
        @built_at = monotonic
      ensure
        @mutex.unlock
      end
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bundle exec rspec spec/unit/tenant_validator_spec.rb`
Expected: PASS, all six examples green.

- [ ] **Step 5: Commit**

```bash
git add lib/apartment/tenant_validator.rb spec/unit/tenant_validator_spec.rb
git commit -m "Add TenantValidator: memoized set, rebuild-on-miss, TTL"
```

---

## Task 3: `TenantValidator` — lifecycle invalidation, fail-open, shutdown

**Files:**
- Modify: `lib/apartment/tenant_validator.rb`
- Test: `spec/unit/tenant_validator_spec.rb`

`Apartment::Instrumentation` already emits `create.apartment` and `drop.apartment`
notifications (payload includes `tenant:`). The validator subscribes to both.

- [ ] **Step 1: Write the failing tests**

Add to `spec/unit/tenant_validator_spec.rb` inside the `RSpec.describe` block:

```ruby
describe 'lifecycle invalidation' do
  it 'adds a tenant on a create.apartment notification' do
    configure(-> { %w[acme] })
    validator = build_validator
    expect(validator.call('newco')).to(be(false))
    ActiveSupport::Notifications.instrument('create.apartment', tenant: 'newco') {}
    expect(validator.call('newco')).to(be(true))
  end

  it 'removes a tenant on a drop.apartment notification' do
    configure(-> { %w[acme widgets] })
    validator = build_validator
    expect(validator.call('widgets')).to(be(true))
    ActiveSupport::Notifications.instrument('drop.apartment', tenant: 'widgets') {}
    expect(validator.call('widgets')).to(be(false))
  end

  it 'stops responding to notifications after #shutdown' do
    configure(-> { %w[acme] })
    validator = build_validator
    validator.shutdown
    ActiveSupport::Notifications.instrument('create.apartment', tenant: 'newco') {}
    expect(validator.call('newco')).to(be(false))
  end
end

describe 'fail-open on source error' do
  it 'allows any name when tenants_provider raises' do
    configure(-> { raise StandardError, 'provider down' })
    expect(build_validator.call('anything')).to(be(true))
  end
end
```

The Task 2 specs continue to pass — `build_validator` and the `after`-shutdown
hook are already in the file, and the new `#shutdown` makes the `respond_to?`
guard active.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec rspec spec/unit/tenant_validator_spec.rb -e lifecycle -e fail-open`
Expected: FAIL — `#shutdown` undefined; notifications do not change the set; a raising provider raises instead of failing open.

- [ ] **Step 3: Add lifecycle, fail-open, and shutdown**

In `lib/apartment/tenant_validator.rb`, replace the `initialize` method and add the new behavior. New `initialize`:

```ruby
    def initialize(positive_ttl: DEFAULT_POSITIVE_TTL_SECONDS,
                   rebuild_interval: DEFAULT_REBUILD_INTERVAL_SECONDS)
      @positive_ttl = positive_ttl
      @rebuild_interval = rebuild_interval
      @names = Concurrent::Set.new
      @mutex = Mutex.new
      @built_at = nil
      @last_rebuild_at = nil
      @degraded = false
      @subscribers = subscribe_to_lifecycle
    end

    # Remove the ActiveSupport::Notifications subscriptions. Call when
    # discarding a validator (Apartment.clear_config) so subscriptions do
    # not accumulate across a process's lifetime.
    def shutdown
      @subscribers.each { |s| ActiveSupport::Notifications.unsubscribe(s) }
      @subscribers = []
    end
```

Replace `call` so a degraded validator fails open:

```ruby
    def call(name)
      name = name.to_s
      rebuild if @built_at.nil? || stale?
      return true if @degraded
      return true if @names.include?(name)

      rebuild_on_miss
      @degraded || @names.include?(name)
    end
    alias valid? call
```

Replace `stale?` so a degraded validator retries on the (short) rebuild interval rather than the (long) TTL:

```ruby
    def stale?
      return false unless @built_at

      ttl = @degraded ? @rebuild_interval : @positive_ttl
      (monotonic - @built_at) > ttl
    end
```

Replace `rebuild` with a fail-open `rescue`:

```ruby
    def rebuild
      return unless @mutex.try_lock

      begin
        @last_rebuild_at = monotonic
        names = Array(Apartment.config.tenants_provider.call).map(&:to_s)
        @names = Concurrent::Set.new(names)
        @degraded = false
        @built_at = monotonic
      rescue StandardError => e
        # Fail open: a broken tenants_provider must not blanket-404 the app.
        @degraded = true
        @built_at = monotonic
        warn_degraded(e)
      ensure
        @mutex.unlock
      end
    end
```

Add the private helpers:

```ruby
    def subscribe_to_lifecycle
      [
        ActiveSupport::Notifications.subscribe('create.apartment') do |*args|
          name = args.last[:tenant]
          @names.add(name.to_s) if name
        end,
        ActiveSupport::Notifications.subscribe('drop.apartment') do |*args|
          name = args.last[:tenant]
          @names.delete(name.to_s) if name
        end,
      ]
    end

    def warn_degraded(error)
      message = '[Apartment] tenant validation degraded: tenants_provider raised ' \
                "#{error.class}: #{error.message}. Allowing all tenants until it recovers."
      if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
        Rails.logger.error(message)
      else
        warn(message)
      end
    end
```

Add `require 'active_support/notifications'` to the top of the file.

- [ ] **Step 4: Run the full validator spec to verify it passes**

Run: `bundle exec rspec spec/unit/tenant_validator_spec.rb`
Expected: PASS — all examples green, output clean (the fail-open spec logs an error line; that is expected).

- [ ] **Step 5: Commit**

```bash
git add lib/apartment/tenant_validator.rb spec/unit/tenant_validator_spec.rb
git commit -m "TenantValidator: lifecycle invalidation, fail-open, shutdown"
```

---

## Task 4: `Apartment.tenant_validator` resolver

**Files:**
- Modify: `lib/apartment.rb`
- Test: `spec/unit/apartment_spec.rb`

`Apartment.tenant_validator` resolves `config.tenant_validator`: `false` → an
always-true callable; `nil` → the process's built-in `TenantValidator` (memoized);
a callable → returned as-is. The built-in is torn down on `clear_config`/`configure`.

- [ ] **Step 1: Write the failing tests**

Add to `spec/unit/apartment_spec.rb`:

```ruby
describe '.tenant_validator' do
  it 'returns an always-true callable when config.tenant_validator is false' do
    described_class.configure do |c|
      c.tenant_strategy = :schema
      c.tenants_provider = -> { [] }
      c.tenant_validator = false
    end
    expect(described_class.tenant_validator.call('anything')).to(be(true))
  end

  it 'returns the configured callable when one is set' do
    custom = ->(name) { name == 'acme' }
    described_class.configure do |c|
      c.tenant_strategy = :schema
      c.tenants_provider = -> { [] }
      c.tenant_validator = custom
    end
    expect(described_class.tenant_validator).to(equal(custom))
  end

  it 'returns a built-in TenantValidator when unset, memoized per process' do
    described_class.configure do |c|
      c.tenant_strategy = :schema
      c.tenants_provider = -> { [] }
    end
    first = described_class.tenant_validator
    expect(first).to(be_a(Apartment::TenantValidator))
    expect(described_class.tenant_validator).to(equal(first))
  end

  it 'discards the built-in validator on clear_config' do
    described_class.configure do |c|
      c.tenant_strategy = :schema
      c.tenants_provider = -> { [] }
    end
    first = described_class.tenant_validator
    described_class.clear_config
    described_class.configure do |c|
      c.tenant_strategy = :schema
      c.tenants_provider = -> { [] }
    end
    expect(described_class.tenant_validator).not_to(equal(first))
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec rspec spec/unit/apartment_spec.rb -e tenant_validator`
Expected: FAIL — `tenant_validator` is not a method on `Apartment`.

- [ ] **Step 3: Add the resolver and teardown**

In `lib/apartment.rb`, add `require_relative 'apartment/tenant_validator'` with the other requires near the top of the file (next to the existing `require_relative` lines).

Add a constant and the resolver method inside `module Apartment; class << self` (near `def adapter`):

```ruby
    # An always-valid validator, used when config.tenant_validator is false.
    ALWAYS_VALID_TENANT = ->(_name) { true }

    # Resolves config.tenant_validator to a callable: false -> always valid,
    # nil -> the process's built-in TenantValidator (memoized), a callable ->
    # itself.
    def tenant_validator
      case (configured = @config&.tenant_validator)
      when false then ALWAYS_VALID_TENANT
      when nil then (@built_in_tenant_validator ||= TenantValidator.new)
      else configured
      end
    end
```

In `clear_config`, before `@config = nil`, add the built-in teardown:

```ruby
      @built_in_tenant_validator&.shutdown
      @built_in_tenant_validator = nil
```

In `configure`, in the "tear down old state and swap in new" section (after `teardown_old_state`), add:

```ruby
      @built_in_tenant_validator&.shutdown
      @built_in_tenant_validator = nil
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bundle exec rspec spec/unit/apartment_spec.rb`
Expected: PASS, all examples green.

- [ ] **Step 5: Commit**

```bash
git add lib/apartment.rb spec/unit/apartment_spec.rb
git commit -m "Add Apartment.tenant_validator resolver with built-in teardown"
```

---

## Task 5: `Generic#call` — validate before switch, route not-found

**Files:**
- Modify: `lib/apartment/elevators/generic.rb`
- Test: `spec/unit/elevators/generic_spec.rb`

- [ ] **Step 1: Write the failing tests**

Add to `spec/unit/elevators/generic_spec.rb` a context for validation. Use a
processor proc so no real request parsing is needed:

```ruby
describe 'tenant validation' do
  let(:app) { ->(_env) { [200, {}, ['ok']] } }
  let(:env) { Rack::MockRequest.env_for('http://acme.example.com/') }

  before do
    Apartment.configure do |c|
      c.tenant_strategy = :schema
      c.default_tenant = 'public'
      c.tenants_provider = -> { %w[acme] }
    end
  end

  it 'switches when the resolved tenant is valid' do
    switched = nil
    allow(Apartment::Tenant).to(receive(:switch)) { |name, &blk| switched = name; blk.call }
    elevator = described_class.new(app, ->(_req) { 'acme' })
    elevator.call(env)
    expect(switched).to(eq('acme'))
  end

  it 'raises TenantNotFound when the resolved tenant is invalid and no handler is set' do
    elevator = described_class.new(app, ->(_req) { 'ghost' })
    expect { elevator.call(env) }.to(raise_error(Apartment::TenantNotFound, /ghost/))
  end

  it 'calls tenant_not_found_handler when configured, returning its Rack response' do
    Apartment.configure do |c|
      c.tenant_strategy = :schema
      c.default_tenant = 'public'
      c.tenants_provider = -> { %w[acme] }
      c.tenant_not_found_handler = ->(tenant, _request) { [404, {}, ["no #{tenant}"]] }
    end
    elevator = described_class.new(app, ->(_req) { 'ghost' })
    expect(elevator.call(env)).to(eq([404, {}, ['no ghost']]))
  end

  it 'does not validate when the processor returns nil (default tenant)' do
    elevator = described_class.new(app, ->(_req) { nil })
    expect(elevator.call(env)).to(eq([200, {}, ['ok']]))
  end

  it 'treats the default tenant as always valid' do
    switched = nil
    allow(Apartment::Tenant).to(receive(:switch)) { |name, &blk| switched = name; blk.call }
    elevator = described_class.new(app, ->(_req) { 'public' })
    elevator.call(env)
    expect(switched).to(eq('public'))
  end

  it 'routes a TenantNotFound raised during resolution through the handler' do
    Apartment.configure do |c|
      c.tenant_strategy = :schema
      c.default_tenant = 'public'
      c.tenants_provider = -> { %w[acme] }
      c.tenant_not_found_handler = ->(_tenant, _request) { [404, {}, ['routed']] }
    end
    processor = ->(_req) { raise Apartment::TenantNotFound, 'unmapped host' }
    elevator = described_class.new(app, processor)
    expect(elevator.call(env)).to(eq([404, {}, ['routed']]))
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec rspec spec/unit/elevators/generic_spec.rb -e 'tenant validation'`
Expected: FAIL — the elevator switches unconditionally; no validation, no handler.

- [ ] **Step 3: Rewrite `Generic#call`**

Replace the `call` method in `lib/apartment/elevators/generic.rb` and add private helpers:

```ruby
      def call(env)
        request = Rack::Request.new(env)

        begin
          database = @processor.call(request)
        rescue Apartment::TenantNotFound
          # HostHash and similar raise during resolution; route through the
          # same handler. The rescue is narrow — it does NOT wrap @app.call,
          # so a TenantNotFound raised by the application is never swallowed.
          return handle_tenant_not_found(request.host, request)
        end

        return @app.call(env) if database.nil?
        return handle_tenant_not_found(database, request) unless tenant_valid?(database)

        Apartment::Tenant.switch(database) { @app.call(env) }
      end

      def parse_tenant_name(_request)
        raise(NotImplementedError, "#{self.class}#parse_tenant_name must be implemented")
      end

      private

      def tenant_valid?(database)
        return true if database.to_s == Apartment.config.default_tenant.to_s

        Apartment.tenant_validator.call(database)
      end

      def handle_tenant_not_found(tenant, request)
        handler = Apartment.config&.tenant_not_found_handler
        return handler.call(tenant, request) if handler

        raise(Apartment::TenantNotFound, "No tenant found for #{tenant.inspect}")
      end
```

`require 'apartment/errors'` is already pulled in via `apartment/tenant`; no new require needed.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bundle exec rspec spec/unit/elevators/generic_spec.rb`
Expected: PASS — the new validation context plus the pre-existing `Generic` specs.

- [ ] **Step 5: Run the full elevator suite for regressions**

Run: `bundle exec rspec spec/unit/elevators/`
Expected: PASS — `Subdomain`, `Domain`, `Host`, `FirstSubdomain`, `Header`, `HostHash` all inherit `call`; confirm none regressed. If a `HostHash` spec asserted a raw `TenantNotFound` raise, update it to expect the handler path when a handler is configured (the raise still happens when none is).

- [ ] **Step 6: Commit**

```bash
git add lib/apartment/elevators/generic.rb spec/unit/elevators/generic_spec.rb
git commit -m "Generic elevator: validate tenant before switch, route not-found"
```

---

## Task 6: Railtie — map `TenantNotFound` to `:not_found`

**Files:**
- Modify: `lib/apartment/railtie.rb`
- Test: `spec/unit/railtie_spec.rb`

- [ ] **Step 1: Write the failing test**

Add to `spec/unit/railtie_spec.rb`:

```ruby
describe 'TenantNotFound rescue_responses mapping' do
  it 'maps Apartment::TenantNotFound to :not_found' do
    require 'action_dispatch'
    # The railtie initializer registers the mapping at boot.
    expect(ActionDispatch::ExceptionWrapper.rescue_responses['Apartment::TenantNotFound'])
      .to(eq(:not_found))
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bundle exec rspec spec/unit/railtie_spec.rb -e rescue_responses`
Expected: FAIL — the key is unset (`nil`).

- [ ] **Step 3: Add the railtie initializer**

In `lib/apartment/railtie.rb`, inside the `class Railtie`, add a new initializer
(after the `'apartment.middleware'` initializer block, before `if Rails.env.test?`):

```ruby
    # Map Apartment::TenantNotFound to a 404 so an unknown tenant renders the
    # application's own 404 page when no tenant_not_found_handler is configured.
    # `||=` so an app that sets its own mapping is not overridden.
    initializer 'apartment.rescue_responses' do
      require 'action_dispatch'
      ActionDispatch::ExceptionWrapper.rescue_responses['Apartment::TenantNotFound'] ||= :not_found
    end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bundle exec rspec spec/unit/railtie_spec.rb`
Expected: PASS. (If `railtie_spec.rb` boots the railtie via a dummy app, the mapping is registered; if it tests initializers in isolation, run the initializer block directly in the spec setup — match the file's existing pattern.)

- [ ] **Step 5: Commit**

```bash
git add lib/apartment/railtie.rb spec/unit/railtie_spec.rb
git commit -m "Railtie: map Apartment::TenantNotFound to :not_found"
```

---

## Task 7: Documentation — resolve the contradiction, CHANGELOG

**Files:**
- Modify: `docs/designs/v4-elevators.md`
- Modify: `docs/designs/apartment-v4.md`
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Rewrite the v4-elevators.md "Error Handling" section**

In `docs/designs/v4-elevators.md`, replace the "Error Handling" section (the one
stating Generic does not rescue and `tenant_not_found_handler` is "an
adapter-level hook"). New content:

```markdown
## Error Handling

`Generic#call` validates the resolved tenant name before switching, via
`config.tenant_validator` (a built-in in-process validator by default). An
unknown tenant is routed through `config.tenant_not_found_handler` if one is
configured (it returns a Rack response), otherwise `Apartment::TenantNotFound`
is raised. The railtie maps that exception to `:not_found`.

A `TenantNotFound` raised during resolution itself — e.g. `HostHash` on an
unmapped host — is caught narrowly around the processor call and routed through
the same handler. The rescue does not wrap `@app.call`, so an application's own
`TenantNotFound` is never swallowed.

See `docs/designs/elevator-tenant-validation.md` for the full design.
```

- [ ] **Step 2: Reconcile apartment-v4.md**

In `docs/designs/apartment-v4.md`, find the "Tenant not found" line (the one near
the `tenant_not_found_handler` example) and ensure it reads as elevator-level and
points at the new design doc. Change any "adapter-level" phrasing to elevator-level.
Add, next to the `tenant_not_found_handler` config example, a one-line cross-reference:
`# See docs/designs/elevator-tenant-validation.md`.

- [ ] **Step 3: Add the CHANGELOG entry**

In `CHANGELOG.md`, under the current unreleased/alpha section, add:

```markdown
- **Breaking (alpha):** elevators now validate the resolved tenant before
  switching. An unknown subdomain raises `Apartment::TenantNotFound` (mapped to
  a 404) instead of failing deep in the first query with an opaque 500.
  Validation runs by default via a built-in in-process validator; disable with
  `config.tenant_validator = false`, or customize with a callable. Configure
  `config.tenant_not_found_handler` for a custom response.
```

- [ ] **Step 4: Commit**

```bash
git add docs/designs/v4-elevators.md docs/designs/apartment-v4.md CHANGELOG.md
git commit -m "Docs: elevator-level tenant-not-found handling; CHANGELOG"
```

---

## Task 8: Integration test — unknown subdomain returns 404

**Files:**
- Modify: `spec/integration/v4/request_lifecycle_spec.rb`

The dummy app already boots with the `:subdomain` elevator and a
`tenants_provider`. An unknown subdomain should now fail closed.

- [ ] **Step 1: Write the failing test**

Add to `spec/integration/v4/request_lifecycle_spec.rb`, inside the existing
`describe 'v4 Request lifecycle'` block:

```ruby
it 'returns 404 for an unknown subdomain instead of a 500' do
  header 'Host', 'ghost.example.com'
  get '/tenant_info'
  expect(last_response.status).to(eq(404))
end

it 'switches normally for a known tenant (validation does not block valid tenants)' do
  header 'Host', 'acme.example.com'
  get '/tenant_info'
  expect(last_response).to(be_ok)
  expect(JSON.parse(last_response.body)['tenant']).to(eq('acme'))
end
```

The dummy app's `tenants_provider` must list the test tenants for the built-in
validator to accept them. Confirm `spec/dummy/config/initializers/apartment.rb`'s
`tenants_provider` returns `acme`/`widgets` during the spec (the `before` hook
creates those tenants); if it sources from an empty `Company` table, set the
dummy `tenants_provider` to `-> { %w[public acme widgets] }` or have the `before`
hook populate `Company`. The unknown-subdomain raise relies on the railtie's
`rescue_responses` mapping; the dummy app must boot the railtie (it does — see
the explicit `require 'apartment/railtie'` in `spec/dummy/config/application.rb`).

- [ ] **Step 2: Run the test to verify it fails (then passes)**

Run: `RAILS_ENV=test DATABASE_ENGINE=postgresql REQUEST_LIFECYCLE_REQUIRED=1 BUNDLE_GEMFILE=gemfiles/rails_8.1_postgresql.gemfile bundle exec rspec spec/integration/v4/request_lifecycle_spec.rb`
Expected: with the validation code from Tasks 1–6 in place, the 404 test PASSES and the known-tenant test PASSES. If the 404 test errors with a 500, inspect whether the dummy `tenants_provider` lists the valid tenants and whether `rescue_responses` is registered.

- [ ] **Step 3: Run the full integration suite for regressions**

Run: `RAILS_ENV=test DATABASE_ENGINE=postgresql REQUEST_LIFECYCLE_REQUIRED=1 BUNDLE_GEMFILE=gemfiles/rails_8.1_postgresql.gemfile bundle exec rspec spec/integration/v4/`
Expected: PASS — no regressions; the request_lifecycle examples that switch to real tenants still pass (their tenants are valid).

- [ ] **Step 4: Commit**

```bash
git add spec/integration/v4/request_lifecycle_spec.rb spec/dummy/config/initializers/apartment.rb
git commit -m "Integration: unknown subdomain returns 404"
```

---

## Final verification

- [ ] Run the full unit suite: `bundle exec rspec spec/unit/` — expect 0 failures.
- [ ] Run rubocop on every changed file: `bundle exec rubocop <files>` — expect 0 offenses.
- [ ] Run the integration suite on PostgreSQL (command in Task 8 Step 3) — expect 0 failures.
- [ ] Open the PR; CHANGELOG entry present; design doc linked.

---

## Self-review notes

- **Spec coverage:** Two seams (Tasks 1, 4, 5); built-in validator with set / rebuild-on-miss / rate-limit / single-flight / TTL / lifecycle / fail-open (Tasks 2, 3); railtie mapping (Task 6); doc-contradiction resolution (Task 7); on-by-default + breaking-change note (Task 7 CHANGELOG); edge cases — `nil` name, `default_tenant` always valid, `HostHash` routing (Task 5 tests). Multi-process behavior is a property of the validator (Tasks 2–3), not separate code.
- **Out of scope (per spec):** programmatic `Tenant.switch` validation, distributed cache, multi-source resolution — no tasks, intentionally.
- **Naming consistency:** `Apartment.tenant_validator` (resolver), `Apartment::TenantValidator` (class), `config.tenant_validator` / `config.tenant_not_found_handler` (config), `#shutdown` (teardown) — used consistently across Tasks 2–6.
- **Known follow-up for the executor:** the built-in `TenantValidator` is process-global; if any new count-sensitive spec exercises it, isolate its state per example (see the pinned-model registry note in `spec/CLAUDE.md`).
