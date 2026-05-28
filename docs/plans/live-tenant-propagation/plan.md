# Live Tenant Propagation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `Apartment::Tenant.current` survive the `ActionController::Live` thread-spawn boundary under `:fiber` isolation on Rails 7.2 – 8.1.1 (and remain correct on 8.1.2+), without monkey-patching `:nodoc:` Rails internals or introducing thread-keyed state.

**Architecture:** Three pieces wired by the Apartment Railtie. (1) A new constant `Apartment::ENV_TENANT_KEY = "apartment.tenant"` and a one-line addition to `Apartment::Elevators::Generic#call` that stashes the resolved tenant on `request.env` (the cross-thread carrier). (2) A new `Apartment::LiveTenancy` concern at `lib/apartment/concerns/live_tenancy.rb` that adds an `around_action` reading the env value and re-entering `Apartment::Tenant.switch` from inside the spawned thread. (3) A new `initializer 'apartment.live_tenancy'` in the Railtie that auto-includes the concern into `ActionController::Live` via Concern-into-Concern composition — every Live controller picks up the around_action without user opt-in.

**Tech Stack:** Ruby, Rails (`ActionController::Live`, `ActiveSupport::Concern`, `ActiveSupport::IsolatedExecutionState`), RSpec, Appraisal (Rails matrix), Rack.

**Design spec:** `docs/designs/rails-boundary-tenancy.md` § Worked example: ActionController::Live (#304).

---

## File map

**Create:**
- `lib/apartment/concerns/live_tenancy.rb` — `Apartment::LiveTenancy` concern with the `around_action`.
- `spec/unit/live_tenancy_spec.rb` — unit tests for the concern: `included do` adds the callback, `_apartment_with_live_tenant` switches when env set, falls through when not, restores on raise.
- `spec/dummy/app/controllers/streaming_controller.rb` — Live controller exercised by integration spec (recovered from `stash@{0}`).
- `spec/integration/v4/live_streaming_spec.rb` — integration test against the dummy app: real HTTP, real Subdomain elevator, real Live action; asserts tenant continuity inside `response.stream.write` under both `:thread` and `:fiber`.

**Modify:**
- `lib/apartment.rb` — add `ENV_TENANT_KEY = "apartment.tenant"` constant after the `module Apartment` declaration.
- `lib/apartment/elevators/generic.rb` — one-line `env[Apartment::ENV_TENANT_KEY] = database` before the `Apartment::Tenant.switch` call.
- `lib/apartment/railtie.rb` — new `initializer 'apartment.live_tenancy'` block that force-loads `action_controller/metal/live` and includes `Apartment::LiveTenancy` into `ActionController::Live`.
- `spec/dummy/config/routes.rb` — add `get '/stream' => 'streaming#show'` (recovered from stash).
- `spec/unit/elevators/generic_spec.rb` — add `env stash` describe block.
- `spec/unit/elevators/subdomain_spec.rb` — add inheritance test asserting Subdomain (via `super`) picks up the env stash.
- `spec/unit/railtie_spec.rb` — add `apartment.live_tenancy initializer` describe block.
- `docs/designs/apartment-v4.md` — update the #304 row and the inline Live caveat (~line 75) to point at `docs/designs/rails-boundary-tenancy.md`.
- `docs/upgrading-to-v4.md` — replace the "wrap Live actions in explicit `Apartment::Tenant.switch`" instruction with the auto-propagation note + three caveats (nested user threads, custom elevator subclasses, app-defined around_action ordering).
- `README.md` — add a "ActionController::Live streaming" section showing the now-out-of-the-box behavior.

---

### Task 1: Recover dummy-app infrastructure from stash

**Why first:** the integration test (Task 8) needs the dummy streaming controller and route already in place. Recovering from `stash@{0}` is faster and gives us bytewise-identical content to what was tested before.

**Files:**
- Create: `spec/dummy/app/controllers/streaming_controller.rb`
- Modify: `spec/dummy/config/routes.rb`

- [ ] **Step 1: Inspect the stash for the two files**

```bash
git show "stash@{0}^3:spec/dummy/app/controllers/streaming_controller.rb"
git stash show -p stash@{0} -- spec/dummy/config/routes.rb
```

Expected: the streaming controller body (an `ActionController::Live` controller with `def show`) and the routes patch adding `get '/stream' => 'streaming#show'`.

- [ ] **Step 2: Restore the streaming controller**

```bash
git show "stash@{0}^3:spec/dummy/app/controllers/streaming_controller.rb" > spec/dummy/app/controllers/streaming_controller.rb
```

Expected content (verify after restore):

```ruby
class StreamingController < ApplicationController
  include ActionController::Live

  def show
    response.headers['Content-Type'] = 'text/event-stream'
    response.headers['Cache-Control'] = 'no-cache'
    payload = { tenant: Apartment::Tenant.current, user_count: User.count }
    response.stream.write("data: #{payload.to_json}\n\n")
  ensure
    response.stream.close
  end
end
```

If the stashed content differs, overwrite with the body above — this is what the integration spec assumes.

- [ ] **Step 3: Apply the routes patch**

```bash
git stash show -p stash@{0} -- spec/dummy/config/routes.rb | git apply
```

Verify by running:

```bash
git diff spec/dummy/config/routes.rb
```

Expected diff: one `+` line `get '/stream' => 'streaming#show'` inside `Rails.application.routes.draw do ... end`. If the patch context is stale (it may not be on `main`), open `spec/dummy/config/routes.rb` and add that single line manually inside the `draw` block before any catch-all.

- [ ] **Step 4: Verify dummy still boots**

```bash
bundle exec appraisal rails-8.1-sqlite3 rspec spec/dummy/config/routes.rb 2>/dev/null || true
bundle exec appraisal rails-8.1-sqlite3 rails runner -e test 'puts Rails.application.routes.routes.map(&:path).map(&:spec).grep(/stream/)' 2>&1 | tail
```

Expected: no syntax errors loading the dummy; `/stream(.:format)` appears in the route table.

- [ ] **Step 5: Commit**

```bash
git add spec/dummy/app/controllers/streaming_controller.rb spec/dummy/config/routes.rb
git commit -m "Test: add streaming controller and /stream route to dummy app"
```

---

### Task 2: Add `Apartment::ENV_TENANT_KEY` constant

**Files:**
- Modify: `lib/apartment.rb` (insert near top of module body)
- Test: `spec/unit/apartment_constants_spec.rb` (new file, ~10 lines)

- [ ] **Step 1: Write the failing test**

Create `spec/unit/apartment_constants_spec.rb`:

```ruby
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Apartment do
  describe 'ENV_TENANT_KEY' do
    it 'is the canonical Rack env key for cross-thread tenant lookup' do
      expect(Apartment::ENV_TENANT_KEY).to eq('apartment.tenant')
    end

    it 'is frozen' do
      expect(Apartment::ENV_TENANT_KEY).to be_frozen
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
bundle exec rspec spec/unit/apartment_constants_spec.rb
```

Expected: FAIL with `NameError: uninitialized constant Apartment::ENV_TENANT_KEY`.

- [ ] **Step 3: Add the constant**

In `lib/apartment.rb`, immediately after the `module Apartment # rubocop:disable Metrics/ModuleLength` line (around line 38), add:

```ruby
  # Rack env key used to carry the resolved tenant across execution boundaries
  # (notably the OS thread spawned by ActionController::Live#process). The
  # elevator writes this; Apartment::LiveTenancy reads it.
  ENV_TENANT_KEY = 'apartment.tenant'
```

Note the two-space indent matching the existing module body.

- [ ] **Step 4: Run the test to verify it passes**

```bash
bundle exec rspec spec/unit/apartment_constants_spec.rb
```

Expected: PASS (2 examples).

- [ ] **Step 5: Commit**

```bash
git add lib/apartment.rb spec/unit/apartment_constants_spec.rb
git commit -m "Add Apartment::ENV_TENANT_KEY constant for cross-boundary tenant lookup"
```

---

### Task 3: Stash the tenant on `request.env` in `Elevators::Generic#call`

**Files:**
- Modify: `lib/apartment/elevators/generic.rb` (line 32 area)
- Test: `spec/unit/elevators/generic_spec.rb` (existing file; add one example)

- [ ] **Step 1: Locate the existing generic_spec**

```bash
ls spec/unit/elevators/
```

Expected: `generic_spec.rb` exists. If it doesn't, create it (see Step 2). Read it to understand the existing test scaffolding (`Rack::MockRequest`, the test elevator subclass, etc.).

- [ ] **Step 2: Write the failing test**

Add this example to `spec/unit/elevators/generic_spec.rb` inside the appropriate `describe Apartment::Elevators::Generic do` block. If a `describe '#call'` group exists, add it there; otherwise create one:

```ruby
  describe 'env stash' do
    let(:app) { ->(env) { [200, {}, [env[Apartment::ENV_TENANT_KEY].to_s]] } }
    let(:elevator_class) do
      Class.new(described_class) do
        def parse_tenant_name(request)
          request.host.split('.').first
        end
      end
    end

    before do
      allow(Apartment::Tenant).to receive(:switch).and_yield
      allow(Apartment).to receive(:tenant_validator).and_return(->(_) { true })
      allow(Apartment).to receive(:config).and_return(double(default_tenant: 'public'))
    end

    it 'writes Apartment::ENV_TENANT_KEY on env before invoking the app' do
      env = Rack::MockRequest.env_for('http://acme.example.com/')
      elevator_class.new(app).call(env)
      expect(env[Apartment::ENV_TENANT_KEY]).to eq('acme')
    end

    it 'does not set ENV_TENANT_KEY when no tenant is resolved' do
      no_tenant_elevator = Class.new(described_class) do
        def parse_tenant_name(_request)
          nil
        end
      end
      env = Rack::MockRequest.env_for('http://example.com/')
      no_tenant_elevator.new(app).call(env)
      expect(env).not_to have_key(Apartment::ENV_TENANT_KEY)
    end
  end
```

- [ ] **Step 3: Run the test to verify it fails**

```bash
bundle exec rspec spec/unit/elevators/generic_spec.rb -e 'env stash'
```

Expected: the "writes Apartment::ENV_TENANT_KEY" example FAILs because the elevator doesn't currently set the key. The "does not set" example may pass already (vacuous).

- [ ] **Step 4: Implement the env stash**

In `lib/apartment/elevators/generic.rb`, modify `#call`. Original tail of the method (line 29–33):

```ruby
        return @app.call(env) if database.nil?
        return handle_tenant_not_found(database, request) unless tenant_valid?(database)

        Apartment::Tenant.switch(database) { @app.call(env) }
```

Replace with:

```ruby
        return @app.call(env) if database.nil?
        return handle_tenant_not_found(database, request) unless tenant_valid?(database)

        env[Apartment::ENV_TENANT_KEY] = database
        Apartment::Tenant.switch(database) { @app.call(env) }
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
bundle exec rspec spec/unit/elevators/generic_spec.rb -e 'env stash'
```

Expected: PASS (2 examples).

- [ ] **Step 6: Add a subclass-inheritance test**

Subclasses of `Generic` (`Subdomain`, `HostHash`, `Domain`, `FirstSubdomain`, `Host`, `Header`) all delegate to `Generic#call` via `super` or by not overriding `call`. The env stash must reach those subclasses for free. Add this example to `spec/unit/elevators/subdomain_spec.rb`:

```ruby
  describe 'env stash inheritance' do
    let(:app) { ->(env) { [200, {}, [env[Apartment::ENV_TENANT_KEY].to_s]] } }

    before do
      allow(Apartment::Tenant).to receive(:switch).and_yield
      allow(Apartment).to receive(:tenant_validator).and_return(->(_) { true })
      allow(Apartment).to receive(:config).and_return(double(default_tenant: 'public'))
    end

    it 'inherits env stash behavior from Generic#call (Subdomain via super)' do
      env = Rack::MockRequest.env_for('http://acme.example.com/')
      Apartment::Elevators::Subdomain.new(app).call(env)
      expect(env[Apartment::ENV_TENANT_KEY]).to eq('acme')
    end
  end
```

- [ ] **Step 7: Run the subclass test**

```bash
bundle exec rspec spec/unit/elevators/subdomain_spec.rb -e 'env stash inheritance'
```

Expected: PASS — Subdomain's `parse_tenant_name` returns `'acme'`; `Generic#call` writes the env key.

- [ ] **Step 8: Run the full elevator spec to confirm no regression**

```bash
bundle exec rspec spec/unit/elevators/
```

Expected: all pre-existing examples still PASS.

- [ ] **Step 9: Commit**

```bash
git add lib/apartment/elevators/generic.rb spec/unit/elevators/generic_spec.rb spec/unit/elevators/subdomain_spec.rb
git commit -m "Elevator: stash resolved tenant on request.env for cross-boundary lookup"
```

---

### Task 4: Create `Apartment::LiveTenancy` concern

**Files:**
- Create: `lib/apartment/concerns/live_tenancy.rb`
- Test: `spec/unit/live_tenancy_spec.rb`

The Zeitwerk `loader.collapse("#{__dir__}/apartment/concerns")` line in `lib/apartment.rb` (line 31) maps `concerns/live_tenancy.rb` to `Apartment::LiveTenancy`, not `Apartment::Concerns::LiveTenancy`.

- [ ] **Step 1: Write the failing test**

Create `spec/unit/live_tenancy_spec.rb`:

```ruby
# frozen_string_literal: true

require 'spec_helper'
require 'action_controller'
require 'action_controller/metal/live'

RSpec.describe Apartment::LiveTenancy do
  # A minimal controller-like host that records around_action registration
  # and exposes the private callback method for direct invocation.
  let(:controller_class) do
    Class.new do
      attr_accessor :request

      def self.registered_around_actions
        @registered_around_actions ||= []
      end

      def self.around_action(name)
        registered_around_actions << name
      end

      include Apartment::LiveTenancy
    end
  end

  describe 'when included' do
    it 'registers an around_action callback' do
      expect(controller_class.registered_around_actions)
        .to include(:_apartment_with_live_tenant)
    end
  end

  describe '#_apartment_with_live_tenant' do
    let(:instance) { controller_class.new }
    let(:env) { {} }

    before do
      instance.request = double('Request', env: env)
    end

    context 'when env carries Apartment::ENV_TENANT_KEY' do
      before { env[Apartment::ENV_TENANT_KEY] = 'acme' }

      it 'wraps the block in Apartment::Tenant.switch with the env tenant' do
        expect(Apartment::Tenant).to receive(:switch).with('acme').and_yield
        result = instance.send(:_apartment_with_live_tenant) { 42 }
        expect(result).to eq(42)
      end
    end

    context 'when env has no tenant key' do
      it 'yields without calling Apartment::Tenant.switch' do
        expect(Apartment::Tenant).not_to receive(:switch)
        result = instance.send(:_apartment_with_live_tenant) { 'plain' }
        expect(result).to eq('plain')
      end
    end

    context 'when the block raises' do
      before { env[Apartment::ENV_TENANT_KEY] = 'acme' }

      it 'propagates the exception (switch handles restore via its own ensure)' do
        allow(Apartment::Tenant).to receive(:switch).with('acme').and_yield
        expect {
          instance.send(:_apartment_with_live_tenant) { raise 'boom' }
        }.to raise_error('boom')
      end
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
bundle exec rspec spec/unit/live_tenancy_spec.rb
```

Expected: FAIL with `NameError: uninitialized constant Apartment::LiveTenancy`.

- [ ] **Step 3: Create the concern**

Create `lib/apartment/concerns/live_tenancy.rb`:

```ruby
# frozen_string_literal: true

require 'active_support/concern'

module Apartment
  # Re-establishes the request's tenant inside the OS thread that
  # ActionController::Live spawns for streaming responses. Auto-included
  # into ActionController::Live by the Apartment Railtie; every controller
  # that includes ActionController::Live picks up this around_action via
  # ActiveSupport::Concern composition.
  #
  # See docs/designs/rails-boundary-tenancy.md for the mechanism and why
  # an around_action (not a prepend on Live#process or new_controller_thread)
  # is the only correct hook on Rails < 8.1.2.
  module LiveTenancy
    extend ActiveSupport::Concern

    included do
      around_action :_apartment_with_live_tenant
    end

    private

    def _apartment_with_live_tenant
      tenant = request.env[Apartment::ENV_TENANT_KEY]
      tenant ? Apartment::Tenant.switch(tenant) { yield } : yield
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bundle exec rspec spec/unit/live_tenancy_spec.rb
```

Expected: PASS (4 examples).

- [ ] **Step 5: Commit**

```bash
git add lib/apartment/concerns/live_tenancy.rb spec/unit/live_tenancy_spec.rb
git commit -m "Add Apartment::LiveTenancy concern with around_action for tenant continuity"
```

---

### Task 5: Auto-include `Apartment::LiveTenancy` into `ActionController::Live` via Railtie

**Files:**
- Modify: `lib/apartment/railtie.rb` (add new `initializer 'apartment.live_tenancy'` block)
- Test: `spec/unit/railtie_spec.rb` (add a `describe '.live_tenancy_auto_include'` group)

- [ ] **Step 1: Read the existing railtie spec layout**

```bash
ls spec/unit/railtie_spec.rb 2>/dev/null && wc -l spec/unit/railtie_spec.rb
```

Expected: file exists. Read its top to understand the test harness (it likely instantiates a Rails::Railtie subclass and calls initializers manually). The new test must follow the same pattern.

- [ ] **Step 2: Write the failing test**

The previous spec used `skip 'already auto-included' if ActionController::Live.include?(Apartment::LiveTenancy)` — but the railtie has already run by the time the railtie spec executes (the test process boots Rails), so that guard nullifies every assertion. The test needs to assert facts that hold regardless of include order:

1. The initializer exists by name.
2. After the initializer has run (whether by the test process boot or invoked here), the include? state is true.
3. A controller class that subsequently includes `ActionController::Live` gets the around_action queued via Concern composition.

Append to `spec/unit/railtie_spec.rb`, inside the top-level `RSpec.describe Apartment::Railtie do` block:

```ruby
  describe 'apartment.live_tenancy initializer' do
    it 'is registered on the railtie by name' do
      names = Apartment::Railtie.initializers.map(&:name)
      expect(names).to include('apartment.live_tenancy')
    end

    it 'has included Apartment::LiveTenancy into ActionController::Live once boot has completed' do
      require 'action_controller/metal/live'
      # The railtie initializer ran during spec process boot; this asserts the
      # observable end state, not the mechanics of running it again.
      expect(ActionController::Live.include?(Apartment::LiveTenancy)).to be(true)
    end

    it 'queues the around_action on every class that subsequently includes ActionController::Live' do
      require 'action_controller'
      require 'action_controller/metal/live'
      # A freshly-built controller class that includes Live (after boot) must
      # pick up the around_action through ActiveSupport::Concern composition.
      fresh_controller = Class.new(ActionController::Base) { include ActionController::Live }
      callbacks = fresh_controller._process_action_callbacks.map(&:filter)
      expect(callbacks).to include(:_apartment_with_live_tenant)
    end

    it 'is idempotent — re-running does not double-include' do
      require 'action_controller/metal/live'
      before_count = ActionController::Live.ancestors.count(Apartment::LiveTenancy)
      initializer = Apartment::Railtie.initializers.find { |i| i.name == 'apartment.live_tenancy' }
      initializer.run(Rails.application)
      after_count = ActionController::Live.ancestors.count(Apartment::LiveTenancy)
      expect(after_count).to eq(before_count)
    end
  end
```

- [ ] **Step 3: Run the test to verify it fails**

```bash
bundle exec rspec spec/unit/railtie_spec.rb -e 'apartment.live_tenancy'
```

Expected: the first example fails because no initializer named `apartment.live_tenancy` is registered yet.

- [ ] **Step 4: Add the initializer in the Railtie**

In `lib/apartment/railtie.rb`, add the following block. Place it after the existing `initializer 'apartment.rescue_responses'` block (the rescue_responses initializer is the closest existing match — both are unconditional initializers without ordering constraints):

```ruby
    # Auto-include Apartment::LiveTenancy into ActionController::Live so every
    # controller that includes Live picks up the around_action that re-establishes
    # the request's tenant inside the OS thread Live spawns for streaming.
    #
    # The :action_controller_live load hook only exists on Rails main (8.2+);
    # we force-require Live and include unconditionally so the fix lands on
    # Rails 7.2 / 8.0 / 8.1 — exactly the versions where Rails' own share_with
    # propagation is buggy under :fiber. On Rails 8.1.2+, share_with(context)
    # already carries the tenant; the around_action runs as a redundant no-op
    # same-tenant switch.
    #
    # See docs/designs/rails-boundary-tenancy.md.
    initializer 'apartment.live_tenancy' do
      next unless defined?(ActionController::Base)  # non-ActionPack apps (rare; ActiveRecord-only)
      require 'action_controller/metal/live'
      next if ActionController::Live.include?(Apartment::LiveTenancy)

      ActionController::Live.include(Apartment::LiveTenancy)
    end
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
bundle exec rspec spec/unit/railtie_spec.rb -e 'apartment.live_tenancy'
```

Expected: PASS (2 examples).

- [ ] **Step 6: Run the full railtie spec for regression**

```bash
bundle exec rspec spec/unit/railtie_spec.rb
```

Expected: all examples PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/apartment/railtie.rb spec/unit/railtie_spec.rb
git commit -m "Railtie: auto-include Apartment::LiveTenancy into ActionController::Live"
```

---

### Task 6: Integration test — scaffolding + Live under `:thread` isolation (baseline)

**Harness pattern:** modeled on `spec/integration/v4/request_lifecycle_spec.rb` — it's the only existing v4 integration spec that boots the dummy app + issues HTTP + reads JSON from the response. The harness rules:

1. `require 'spec_helper'; require_relative 'support'` — there is no `integration_spec_helper`.
2. `DUMMY_APP_AVAILABLE` guard at file top: `require_relative('../../dummy/config/environment')` + `require('rack/test')`, rescued to a skip-with-warn (unless `REQUEST_LIFECYCLE_REQUIRED=1`).
3. `V4IntegrationHelper.postgresql?` skip: the dummy app's `database.yml` is PostgreSQL-only.
4. `spec_helper.rb`'s `config.after do Apartment.clear_config; Apartment::Current.reset end` runs after every example — so `before(:all) { Apartment.configure ... }` does not survive. Each example must call `establish_apartment!` (load the dummy's `config/initializers/apartment.rb` + `Apartment.activate!` + `Apartment::Tenant.init`) in a per-example `before`.
5. `before` creates the tenants and rebuilds the `users` table per example (matches `request_lifecycle_spec.rb` lines ~58–80).
6. `after(:all)` drops tenants and clears apartment state so the suite leaves no residue for the next spec file.
7. Run command: `DATABASE_ENGINE=postgresql bundle exec appraisal rails-8.1-postgresql rspec ...` — not `rails-8.1-sqlite3`.

**Why this comes before `:fiber`:** under `:thread` isolation, Rails' own `share_with(Thread.current)` propagates state correctly without the new around_action doing anything load-bearing. This task validates the harness works (the dummy boots, the elevator+route+controller round-trip), so Task 7 can change isolation_level and isolate the bug.

**Files:**
- Create: `spec/integration/v4/live_streaming_spec.rb`

- [ ] **Step 1: Read the canonical pattern**

```bash
sed -n '1,30p' spec/integration/v4/request_lifecycle_spec.rb
sed -n '40,100p' spec/integration/v4/request_lifecycle_spec.rb
```

Confirm: file top has `DUMMY_APP_AVAILABLE` + `RSpec.describe(..., skip: ...)`; per-example `before` calls `establish_apartment!` and rebuilds tables; `after(:all)` drops tenants and clears config.

- [ ] **Step 2: Write the integration spec**

Create `spec/integration/v4/live_streaming_spec.rb`:

```ruby
# frozen_string_literal: true

# Live streaming + tenant propagation requires the dummy Rails app + real PostgreSQL
# (the dummy app's database.yml is PG-only). Modeled on request_lifecycle_spec.rb.
# Run via: DATABASE_ENGINE=postgresql bundle exec appraisal rails-8.1-postgresql \
#   rspec spec/integration/v4/live_streaming_spec.rb

require 'spec_helper'
require_relative 'support'

ENV['RAILS_ENV'] ||= 'test'

LIVE_STREAMING_DUMMY_AVAILABLE = begin
  require_relative('../../dummy/config/environment')
  require('rack/test')
  require('json')
  true
rescue LoadError, StandardError => e
  raise if ENV['REQUEST_LIFECYCLE_REQUIRED']

  warn "[live_streaming_spec] Skipping: #{e.message}"
  false
end

RSpec.describe(
  'ActionController::Live tenant propagation', :integration, :request_lifecycle,
  skip: (LIVE_STREAMING_DUMMY_AVAILABLE && V4IntegrationHelper.postgresql? ? false : 'requires dummy Rails app + PostgreSQL')
) do
  include Rack::Test::Methods

  def app
    Rails.application
  end

  def test_tenants = %w[acme widgets]

  def establish_apartment!
    load(Rails.root.join('config/initializers/apartment.rb'))
    Apartment.activate!
    Apartment::Tenant.init
  end

  def stream_payload(response)
    JSON.parse(response.body.sub(/\Adata:\s*/, '').strip)
  end

  before do
    establish_apartment!

    test_tenants.each do |tenant|
      Apartment.adapter.create(tenant)
    rescue Apartment::TenantExists
      nil
    end

    [Apartment.config.default_tenant, *test_tenants].each do |tenant|
      Apartment::Tenant.switch(tenant) do
        ActiveRecord::Base.connection.create_table(:users, force: true) do |t|
          t.string(:name)
        end
      end
    end

    Apartment::Tenant.switch('acme')    { User.create!(name: 'A'); User.create!(name: 'B'); User.create!(name: 'C') }
    Apartment::Tenant.switch('widgets') { User.create!(name: 'X') }
  end

  after { Apartment::Current.reset }

  after(:all) do
    establish_apartment!
    test_tenants.each do |tenant|
      Apartment.adapter.drop(tenant)
    rescue StandardError
      nil
    end
    Apartment::Tenant.switch(Apartment.config.default_tenant) do
      ActiveRecord::Base.connection.drop_table(:users, if_exists: true)
    end
  ensure
    Apartment.clear_config
    Apartment::Current.reset
  end

  shared_examples 'propagates tenant into the Live stream' do
    it 'streams the acme tenant (3 users) inside response.stream.write' do
      header 'Host', 'acme.example.com'
      get '/stream'
      expect(last_response).to be_ok
      data = stream_payload(last_response)
      expect(data['tenant']).to eq('acme')
      expect(data['user_count']).to eq(3)
    end

    it 'streams the widgets tenant (1 user) inside response.stream.write' do
      header 'Host', 'widgets.example.com'
      get '/stream'
      expect(last_response).to be_ok
      data = stream_payload(last_response)
      expect(data['tenant']).to eq('widgets')
      expect(data['user_count']).to eq(1)
    end
  end

  context 'under :thread isolation' do
    around do |example|
      original = ActiveSupport::IsolatedExecutionState.isolation_level
      ActiveSupport::IsolatedExecutionState.isolation_level = :thread
      example.run
    ensure
      ActiveSupport::IsolatedExecutionState.isolation_level = original
    end

    include_examples 'propagates tenant into the Live stream'
  end
end
```

- [ ] **Step 3: Run the integration spec under `:thread` on PostgreSQL**

```bash
DATABASE_ENGINE=postgresql bundle exec appraisal rails-8.1-postgresql rspec spec/integration/v4/live_streaming_spec.rb
```

Expected: both `:thread` examples PASS. This confirms the harness works (dummy boots, /stream route resolves, controller streams JSON, JSON parses) without the around_action doing anything load-bearing — under `:thread`, Rails' `share_with(Thread.current)` already carries state.

If the spec is skipped with "requires dummy Rails app + PostgreSQL", set `DATABASE_ENGINE=postgresql` and provision the test DB per `CLAUDE.md` Commands section.

- [ ] **Step 4: Commit**

```bash
git add spec/integration/v4/live_streaming_spec.rb
git commit -m "Test: Live tenant propagation integration spec (thread isolation baseline)"
```

---

### Task 7: Add `:fiber` context to the integration spec — the load-bearing assertion + negative control

**Files:**
- Modify: `spec/integration/v4/live_streaming_spec.rb`

- [ ] **Step 1: Add the `:fiber` context with the propagation examples**

In `spec/integration/v4/live_streaming_spec.rb`, append after the existing `context 'under :thread isolation'` block (still inside the top-level `RSpec.describe`):

```ruby
  context 'under :fiber isolation' do
    around do |example|
      original = ActiveSupport::IsolatedExecutionState.isolation_level
      ActiveSupport::IsolatedExecutionState.isolation_level = :fiber
      example.run
    ensure
      ActiveSupport::IsolatedExecutionState.isolation_level = original
    end

    include_examples 'propagates tenant into the Live stream'
  end
```

- [ ] **Step 2: Add the negative-control example**

Inside the same `context 'under :fiber isolation'` block, after `include_examples`, add the negative control. This proves the fix is *causal* — when the env stash is absent, the bug returns. Without this, a passing fiber example could be coincidental (e.g., Rails 8.1.2+'s native fix masking ours).

```ruby
    it '(negative control) leaks tenant when the elevator does not stash the env key' do
      # Simulate a custom elevator that omits the env stash — alias-swap
      # Generic#call to a variant that does not set Apartment::ENV_TENANT_KEY.
      # The Subdomain elevator inherits Generic#call, so this hits both.
      Apartment::Elevators::Generic.class_eval do
        alias_method :_original_call_for_neg_ctrl, :call
        define_method(:call) do |env|
          request = Rack::Request.new(env)
          begin
            database = @processor.call(request)
          rescue Apartment::TenantNotFound => e
            return handle_tenant_not_found(e.tenant || request.host, request)
          end
          return @app.call(env) if database.nil?
          return handle_tenant_not_found(database, request) unless tenant_valid?(database)

          # NOTE: deliberately omitting `env[Apartment::ENV_TENANT_KEY] = database`
          # — this is what the test reproduces.
          Apartment::Tenant.switch(database) { @app.call(env) }
        end
      end

      begin
        header 'Host', 'acme.example.com'
        get '/stream'
        data = stream_payload(last_response)

        if Gem::Version.new(Rails::VERSION::STRING) >= Gem::Version.new('8.1.2')
          # 8.1.2+ propagates via Rails' own share_with(context) regardless of
          # our env stash. The fix is redundant here; the test is informational.
          expect(data['tenant']).to eq('acme')
        else
          # Pre-8.1.2: without the env stash, the around_action falls through
          # to a plain yield and the spawned thread sees no captured tenant.
          # The streamed tenant is NOT 'acme' — the original leak reproduces.
          expect(data['tenant']).not_to eq('acme')
        end
      ensure
        Apartment::Elevators::Generic.class_eval do
          alias_method :call, :_original_call_for_neg_ctrl
          remove_method :_original_call_for_neg_ctrl
        end
      end
    end
```

The alias-swap is fully reversed in `ensure`, so this example is safe to run in any order alongside the positive examples in the same context.

- [ ] **Step 3: Run the full integration spec on Rails 8.1**

```bash
DATABASE_ENGINE=postgresql bundle exec appraisal rails-8.1-postgresql rspec spec/integration/v4/live_streaming_spec.rb
```

Expected: all 5 examples PASS (2 under `:thread`, 2 propagation + 1 negative-control under `:fiber`).

If the positive `:fiber` examples FAIL with `data['tenant']` returning `'public'` or nil and `data['user_count']` being 0:
1. Railtie initializer didn't run before the dummy controller was loaded — check `ActionController::Live.include?(Apartment::LiveTenancy)` is true after dummy boot.
2. Elevator didn't run on the request — check `request.env['apartment.tenant']` is set on the parent fiber.
3. The streaming controller was loaded before the auto-include — restart the test process.

If the negative-control example FAILS on Rails < 8.1.2 (i.e., the leak does *not* reproduce when env is stripped), the fix may be coincidental rather than causal — investigate before proceeding.

- [ ] **Step 4: Run the same spec across the appraisal matrix on PostgreSQL**

```bash
DATABASE_ENGINE=postgresql bundle exec appraisal rails-7.2-postgresql rspec spec/integration/v4/live_streaming_spec.rb
DATABASE_ENGINE=postgresql bundle exec appraisal rails-8.0-postgresql rspec spec/integration/v4/live_streaming_spec.rb
DATABASE_ENGINE=postgresql bundle exec appraisal rails-main-postgresql rspec spec/integration/v4/live_streaming_spec.rb
```

Expected: all 5 examples PASS on every Rails version. The negative control's `if rails_at_least_812` branch handles the version-aware assertion.

- [ ] **Step 5: Commit**

```bash
git add spec/integration/v4/live_streaming_spec.rb
git commit -m "Test: Live tenant propagation under :fiber + negative control (load-bearing)"
```

---

### Task 8: Integration test — thread pool reuse

**Why:** `ActionController::Live` uses `Concurrent::CachedThreadPool` for streaming workers (`new_controller_thread`). Two consecutive requests to different tenants may reuse the same worker thread. The around_action's `Apartment::Tenant.switch` block form must restore prior state so the second request doesn't see leftover state from the first.

**Files:**
- Modify: `spec/integration/v4/live_streaming_spec.rb`

- [ ] **Step 1: Write the failing test**

Inside the top-level `RSpec.describe`, after the existing contexts, add:

```ruby
  context 'with thread-pool reuse across requests under :fiber' do
    around do |example|
      original = ActiveSupport::IsolatedExecutionState.isolation_level
      ActiveSupport::IsolatedExecutionState.isolation_level = :fiber
      example.run
    ensure
      ActiveSupport::IsolatedExecutionState.isolation_level = original
    end

    it 'does not leak tenant state between consecutive Live requests' do
      header 'Host', 'acme.example.com'
      get '/stream'
      acme_data = stream_payload(last_response)

      header 'Host', 'widgets.example.com'
      get '/stream'
      widgets_data = stream_payload(last_response)

      header 'Host', 'acme.example.com'
      get '/stream'
      acme_data_again = stream_payload(last_response)

      expect(acme_data['tenant']).to eq('acme')
      expect(acme_data['user_count']).to eq(3)
      expect(widgets_data['tenant']).to eq('widgets')
      expect(widgets_data['user_count']).to eq(1)
      expect(acme_data_again['tenant']).to eq('acme')
      expect(acme_data_again['user_count']).to eq(3)
    end
  end
```

- [ ] **Step 2: Run the test**

```bash
DATABASE_ENGINE=postgresql bundle exec appraisal rails-8.1-postgresql rspec spec/integration/v4/live_streaming_spec.rb -e 'thread-pool reuse'
```

Expected: PASS. If a request returns the wrong tenant, the `ensure` in `Apartment::Tenant.switch` is not restoring properly, or the around_action is running too late. Investigate before proceeding.

- [ ] **Step 3: Commit**

```bash
git add spec/integration/v4/live_streaming_spec.rb
git commit -m "Test: Live thread pool reuse does not leak tenant between requests"
```

---

### Task 9: Update v4 design doc — #304 row + inline Live caveat

**Files:**
- Modify: `docs/designs/apartment-v4.md`

- [ ] **Step 1: Find both Live mentions**

```bash
grep -n '#304\|ActionController::Live\|Live\b' docs/designs/apartment-v4.md
```

Expected: at least two locations — the #304 row in the limitations table (around line 928 per the prior stash diff), and an inline "Live" caveat in the early-document caveats section (around line 75 per the stash diff). Both need to change.

- [ ] **Step 2: Replace the #304 row body cell**

The current row body says users must wrap Live actions in `Apartment::Tenant.switch`. Replace with:

```
Resolved via Bucket 1 (auto-include `Apartment::LiveTenancy` into `ActionController::Live`). See `docs/designs/rails-boundary-tenancy.md` § Worked example: ActionController::Live.
```

- [ ] **Step 3: Replace the inline Live caveat**

The early caveats section likely says something like "ActionController::Live requires manual `Apartment::Tenant.switch` wrapping under :fiber." Replace with:

```
**ActionController::Live**: works out of the box under both `:thread` and `:fiber` isolation. Apartment v4 auto-includes `Apartment::LiveTenancy` into `ActionController::Live` (see `docs/designs/rails-boundary-tenancy.md`). User-spawned threads/fibers inside a Live action still require explicit `Apartment::Tenant.switch` wrapping — same contract as everywhere else.
```

- [ ] **Step 4: Verify**

```bash
grep -A3 'ActionController::Live\|#304' docs/designs/apartment-v4.md
```

Expected: both locations updated; no remaining "wrap manually" instructions for the standard Live case.

- [ ] **Step 5: Commit**

```bash
git add docs/designs/apartment-v4.md
git commit -m "Docs: point #304 row and inline Live caveat at the rubric doc"
```

---

### Task 10: Update upgrading guide + README (Live + caveats)

**Files:**
- Modify: `docs/upgrading-to-v4.md`
- Modify: `README.md`

- [ ] **Step 1: Find the Live caveat in the upgrading guide**

```bash
grep -n 'ActionController::Live\|Live\b' docs/upgrading-to-v4.md
```

Expected: a line (around line 166 per the stash diff) saying users must wrap Live actions in `Apartment::Tenant.switch`.

- [ ] **Step 2: Replace with the auto-propagation note + caveats**

Locate the Live paragraph in `docs/upgrading-to-v4.md` and replace its body with:

```markdown
**ActionController::Live**: works out of the box. Apartment v4 auto-includes `Apartment::LiveTenancy` into `ActionController::Live`; every Live controller picks up an `around_action` that re-establishes the request's tenant inside the OS thread Rails spawns for streaming. No user code changes required for the standard case.

Caveats:

- **User-spawned threads or fibers inside a Live action** (`Thread.new { ... }`, `Async { ... }`, raw `Fiber.new`) are not covered by the around_action wrap. Wrap them in `Apartment::Tenant.switch(Apartment::Tenant.current) { ... }` explicitly — same contract `:fiber` isolation imposes everywhere else.
- **Custom elevator subclasses** that override `Apartment::Elevators::Generic#call` without calling `super` will not populate `request.env[Apartment::ENV_TENANT_KEY]`. The around_action falls through to a plain `yield` (no switch), and the Live action runs with the default tenant. Either call `super` from your override, or set `env[Apartment::ENV_TENANT_KEY] = tenant_name` yourself after resolving the tenant.
- **App-defined `around_action`s registered on `ApplicationController`** (or any superclass) run *before* `Apartment::LiveTenancy`'s wrap in the callback chain — they execute against the default tenant. If your app callback hits the DB, declare it on the Live controller itself (so it nests inside the Apartment wrap), or wrap its body in `Apartment::Tenant.switch(request.env[Apartment::ENV_TENANT_KEY]) { ... }`.

See `docs/designs/rails-boundary-tenancy.md` for the mechanism.
```

If the existing "wrap manually" instruction lives outside a Live-specific paragraph (e.g., in a generic "Async" section), keep that section and add a new "ActionController::Live" subsection with the text above.

- [ ] **Step 3: Add a Live section to README.md**

```bash
grep -n 'ActionController::Live\|Live\|## ' README.md | head -30
```

Locate an appropriate insertion point (e.g., after the "Configuration" or "Usage" section; before "Limitations" if one exists). Add:

```markdown
### ActionController::Live streaming

Apartment v4 auto-handles tenant propagation across `ActionController::Live`'s spawned streaming thread under both `:thread` and `:fiber` isolation. Including `ActionController::Live` in your controller is sufficient:

```ruby
class StreamingController < ApplicationController
  include ActionController::Live

  def show
    response.headers['Content-Type'] = 'text/event-stream'
    Apartment::Tenant.current # => the request's tenant, even inside the stream
    response.stream.write("data: ...\n\n")
  ensure
    response.stream.close
  end
end
```

User-spawned threads/fibers inside a Live action (`Thread.new`, `Async {}`, raw `Fiber.new`) escape the auto-wrap and need explicit `Apartment::Tenant.switch` wrapping. See the upgrading guide for the full caveat list.
```

- [ ] **Step 4: Verify both docs**

```bash
grep -A5 'ActionController::Live' docs/upgrading-to-v4.md | head -30
grep -A5 'ActionController::Live' README.md | head -20
```

Expected: auto-propagation note + caveats in upgrading guide; new section in README.

- [ ] **Step 5: Commit**

```bash
git add docs/upgrading-to-v4.md README.md
git commit -m "Docs: upgrading guide + README — Live is auto-handled; caveats documented"
```

---

### Task 11: Rubocop sweep on all changed files

**Per user preference (memory: rubocop-before-push), every changed file must pass rubocop before push.**

- [ ] **Step 1: Identify changed files**

```bash
git diff --name-only origin/main..HEAD
```

Expected output:

```
docs/designs/apartment-v4.md
docs/designs/rails-boundary-tenancy.md
docs/plans/live-tenant-propagation/plan.md
docs/upgrading-to-v4.md
lib/apartment.rb
lib/apartment/concerns/live_tenancy.rb
lib/apartment/elevators/generic.rb
lib/apartment/railtie.rb
spec/dummy/app/controllers/streaming_controller.rb
spec/dummy/config/routes.rb
spec/integration/v4/live_streaming_spec.rb
spec/unit/apartment_constants_spec.rb
spec/unit/elevators/generic_spec.rb
spec/unit/live_tenancy_spec.rb
spec/unit/railtie_spec.rb
```

- [ ] **Step 2: Run rubocop on Ruby files only**

```bash
git diff --name-only origin/main..HEAD | grep -E '\.rb$' | xargs bundle exec rubocop
```

Expected: no offenses. If offenses are reported, fix them inline — do not skip with `# rubocop:disable` unless the offense is genuinely a false positive (rare).

- [ ] **Step 3: Commit any rubocop fixes**

```bash
git add -u
git commit -m "Rubocop: address style offenses on Live tenant propagation" || echo "No rubocop fixes needed"
```

---

### Task 12: Full test sweep across appraisal matrix

**Files:** None (test execution only).

- [ ] **Step 1: Unit tests across all Rails versions**

```bash
bundle exec appraisal rspec spec/unit/
```

Expected: all unit examples PASS across the matrix. The new `spec/unit/live_tenancy_spec.rb`, `spec/unit/apartment_constants_spec.rb`, and the additions to `spec/unit/elevators/generic_spec.rb` and `spec/unit/railtie_spec.rb` must pass on Rails 7.2 / 8.0 / 8.1 / main.

- [ ] **Step 2: Integration tests on SQLite (default)**

```bash
bundle exec appraisal rails-7.2-sqlite3 rspec spec/integration/v4/live_streaming_spec.rb
bundle exec appraisal rails-8.0-sqlite3 rspec spec/integration/v4/live_streaming_spec.rb
bundle exec appraisal rails-8.1-sqlite3 rspec spec/integration/v4/live_streaming_spec.rb
bundle exec appraisal rails-main-sqlite3 rspec spec/integration/v4/live_streaming_spec.rb
```

Expected: all examples PASS on every version.

- [ ] **Step 3: Integration tests on PostgreSQL and MySQL**

```bash
DATABASE_ENGINE=postgresql bundle exec appraisal rails-8.1-postgresql rspec spec/integration/v4/live_streaming_spec.rb
DATABASE_ENGINE=mysql bundle exec appraisal rails-8.1-mysql2 rspec spec/integration/v4/live_streaming_spec.rb
```

Expected: PASS. These require provisioned PG and MySQL test databases per `CLAUDE.md` Commands section.

- [ ] **Step 4: Quick regression sweep — existing integration specs**

```bash
bundle exec appraisal rails-8.1-sqlite3 rspec spec/integration/v4/
```

Expected: all pre-existing integration examples still PASS. The auto-include of `Apartment::LiveTenancy` into `ActionController::Live` is invisible to non-Live controllers, but a regression here would indicate the include is firing on the wrong target.

---

## Self-review (post panel-review revisions)

### Spec coverage

- Rubric Bucket 1 criteria (incl. tightened criterion 5 with identifier-vs-state distinction) → enforced by mechanism choice in Tasks 3–5.
- Bucket 1 worked example design (elevator stash + concern + Railtie auto-include) → Tasks 3, 4, 5.
- "Why direct prepends on the spawn site don't work" → design rationale; referenced from concern source comments in Task 4.
- "Behavior across Rails versions" table → exercised by Task 7 (`:fiber` + matrix) and Task 12 (full sweep).
- "Behavior across isolation levels" table → exercised by Tasks 6 (`:thread`) and 7 (`:fiber`).
- Trade-offs (nested user threads, elevator order, app-defined `around_action` ordering, thread pool reuse) → reuse covered by Task 8; the three doc caveats covered by Task 10.
- Test coverage section of spec → Tasks 4 (unit on concern), 5 (unit on Railtie include + idempotence), 6+7+8 (integration on isolation + reuse + negative control).
- Documentation updates section of spec → Tasks 9 (design doc) and 10 (upgrading guide + README).
- ActiveStorage worked example (Bucket 3) → no code change required; explicitly out of scope.

### Panel-review fixes applied

- **Integration harness rewritten** (blocker from Cursor): Tasks 6/7/8 now use `spec_helper` + `support`, `DUMMY_APP_AVAILABLE` guard, `V4IntegrationHelper.postgresql?`, per-example `establish_apartment!`, PostgreSQL appraisal commands. Mirrors `request_lifecycle_spec.rb`.
- **Task 5 self-nullifying `skip` replaced** (blocker from Cursor): four examples that assert facts regardless of include order, plus an idempotence check.
- **`defined?(ActionController::Base)` guard re-added** to the railtie code (blocker from Codex).
- **Spec/plan reconciled on `initializer` vs `after_initialize`**: spec updated to match plan's `initializer`.
- **Negative-control test added** to Task 7 (Cursor): alias-swap removes the env stash; assertion is Rails-version-aware (8.1.2+ still passes via Rails' own propagation).
- **Subclass-elevator inheritance test added** to Task 3 (Codex).
- **Inline #75 caveat in apartment-v4.md added** to Task 9 (Cursor).
- **README section added** to Task 10 (Cursor).
- **Callback-order trade-off documented** in Task 10's upgrading-guide content (Gemini).

### Placeholder scan

No "TBD" / "TODO" / "fill in details" in any task. All code snippets are complete. All commands are exact with expected output.

### Type consistency

- `Apartment::ENV_TENANT_KEY` used identically in elevator (Task 3), concern (Task 4), and docs (Tasks 9, 10).
- `Apartment::LiveTenancy` module name used consistently across Tasks 4, 5, 9, 10.
- `_apartment_with_live_tenant` callback name used identically in concern (Task 4) and railtie test assertion (Task 5).
- `around_action` arity (passing a symbol, not a block with `yield`) is consistent in the concern and the test expectation.
- `stream_payload` helper defined in Task 6 reused unchanged in Tasks 7 and 8.

---

## Execution handoff

**Plan complete and saved to `docs/plans/live-tenant-propagation/plan.md`. Two execution options:**

**1. Inline Execution (recommended for this plan)** — Tasks are linearly dependent (Task 2 must land before Task 3, etc.) and context-coupled (each step references the previous file state). Per `~/.claude/rules/subagent-vs-inline.md`, inline beats subagent orchestration for sequential plan execution. **REQUIRED SUB-SKILL:** `superpowers:executing-plans`, batched execution with checkpoints between tasks for human review.

**2. Subagent-Driven** — A fresh subagent per task with two-stage review. Higher overhead but stronger per-task isolation. **REQUIRED SUB-SKILL:** `superpowers:subagent-driven-development`. Worth it if you'd rather review each task's diff in isolation before the next one starts.

Which approach?
