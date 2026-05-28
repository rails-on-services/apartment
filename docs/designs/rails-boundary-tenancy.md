# Multi-Tenancy at Rails-Created Execution Boundaries

## Purpose

Rails creates execution and structural boundaries where tenant context can be lost or where multi-tenancy must slot into a framework subsystem: Rack requests, `ActionController::Live`'s spawned thread, ActionCable channel workers, Sidekiq/SolidQueue jobs, ActiveStorage variant pipelines, future async APIs. The gem has historically handled these case by case, sometimes introducing parallel state channels that contradict the v4 design.

This document defines the decision rubric for new (and re-evaluated) integrations. It answers: which boundaries does the gem own, by what mechanism, and what does it explicitly refuse.

## Rubric

Each Rails-created tenancy concern lands in exactly one bucket. Evaluate in order; first match wins.

### Bucket 1: auto-handle in core

All six conditions must hold:

1. The boundary is created by Rails, not by user code.
2. The right policy is mechanical and tenant-agnostic: re-establish the tenant the caller had.
3. Re-establishment is reachable from a public Rails extension point (load hook, `ActiveSupport::Concern` composition, `ActiveSupport::Notifications`, middleware, callback API). No `:nodoc:` overrides; no prepends on private Rails internals.
4. The failure mode on doing nothing is silent (wrong-tenant queries, not raised exceptions).
5. The mechanism writes tenant **state** only through the gem's existing channel (`Apartment::Current` via `CurrentAttributes`) in the *target* execution context. No parallel state stores like `Thread#thread_variable_set`, custom per-subsystem caches, or pointer-mirroring between thread-keyed and fiber-keyed storage. The canonical primitive is `Apartment::Tenant.switch(tenant) { ... }` invoked from inside the boundary's execution context, not from outside it.
   - **Identifiers vs state.** A tenant *identifier* (the name string) may be carried across a boundary through framework-provided request carriers like `Rack::env`, job arguments, or message headers — these are not tenant state channels, they are how Rails already moves request-scoped data between execution contexts. The crossing must be *identifier in*, *`Tenant.switch` out*: the spawned-side code reads the identifier and re-establishes state through `Tenant.switch`. Two reads of the same identifier through two carriers (env + `CurrentAttributes`) are acceptable; two *writes* of state through two channels (`CurrentAttributes` + `Thread.thread_variable_set`) are not.
6. The integration surface is small: a handful of touchpoints with stable signatures across the supported Rails matrix, so core's per-Rails-version maintenance cost stays near zero.

The earlier draft of this rubric permitted "temporarily realigning Rails' execution-state pointers" as in-model. That loophole is closed. Realigning `Thread.current.active_support_execution_state` to point at `Fiber.current.active_support_execution_state` shares a reference between two storage scopes the isolation model was chosen to keep separate; it is a parallel channel by construction, not a use of the existing one.

### Bucket 2: provide a primitive, document a recipe

One or more of:

- Boundary is created by user code (`Thread.new`, `Async {}`, custom fiber).
- The right policy is app-specific (auth flow, broadcast scoping, custom security model).
- Discoverability is acceptable because the user is already authoring integration code.

Mechanism: the same primitive (`Apartment::Tenant.switch`), applied at the user's call site. The gem ships documentation in `docs/integrations/<subsystem>.md`; no prepend, no auto-wiring.

```ruby
# ActionCable example. around_subscribe is app code; the gem ships the recipe.
class ApplicationChannel < ActionCable::Channel::Base
  around_subscribe :with_tenant_context

  def with_tenant_context(&block)
    Apartment::Tenant.switch(current_user.tenant, &block)
  end
end
```

### Bucket 3: companion gem

One or more of:

- The integration surface is large: many Rails touchpoints, signatures that churn across Rails versions, transitive dependencies on subsystem internals.
- The integration is structural, not temporal: model graph, storage layer, route helpers, service configuration.
- The integration can ship independently without churning core API.

Mechanism: a separate gem (`apartment-<subsystem>`), versioned independently, declared as optional in core. Core exposes hooks the companion uses (pinned-model registry, current-tenant accessor); core does not host the companion's logic.

## Anti-patterns

The rubric exists in part to forbid these. They appear when it is bypassed.

- **Parallel state channels.** `Thread#thread_variable_set`, custom fiber storage, or per-subsystem stores that read or write tenant context outside `Apartment::Current`. The hot path (`lib/apartment/patches/connection_handling.rb:12-13`) reads one source: `Apartment::Current.tenant`. Adding fallback sources installs permanent branches and quiet ambiguity, and makes the subsystem whose channel got added special in a way the others are not.
- **Pointer-mirroring across isolation scopes.** Assigning `Thread.current.active_support_execution_state = Fiber.current.active_support_execution_state` (or any variant) to coax Rails' propagation into working under `:fiber`. Two storage scopes were chosen to be separate; sharing a reference between them is a parallel channel masquerading as the existing one. Closed by Bucket 1 criterion 5.
- **Mechanism per subsystem.** If Live uses one storage scheme and ActionCable uses another and Sidekiq uses a third, contributors stop seeing the gem as having a coherent tenancy model. Different mechanisms are acceptable across buckets (1 vs 3); within a bucket they should converge on `Apartment::Tenant.switch`.
- **Auto-handling app-specific policy.** Anything that needs to know about authentication, broadcast scoping, or security policy stays in bucket 2. Auto-wiring it creates the wrong defaults for half of users.
- **Companion-gem absorption.** Pulling structural integrations into core because "we already depend on this" inflates the core's Rails-subsystem skew surface. Resist.

## Current applications

| Boundary | Bucket | Status |
|---|---|---|
| Rack request | 1 | Shipped: `lib/apartment/elevators/generic.rb` |
| Sidekiq 7+ / SolidQueue | 1 | Shipped: `docs/designs/apartment-v4.md` (Sidekiq middleware section) |
| ActionController::Live | 1 | Pending: this doc's worked example |
| ActionCable channel | 2 | Recipe TBD: `docs/integrations/actioncable.md` |
| User `Thread.new` / `Async {}` | 2 | Documented: `docs/upgrading-to-v4.md` |
| Generic ActiveJob (non-Sidekiq, non-SolidQueue) | 2, promotable to 1 | `Apartment::Jobs::ActiveJobExtension` opt-in; promotable if backends without `CurrentAttributes` serialization stay common |
| ActiveStorage | 3 | Out of core; companion gem path |

## Worked example: ActionController::Live (#304)

### Problem

`ActionController::Live#process` spawns an OS thread per streaming response and calls `ActiveSupport::IsolatedExecutionState.share_with(...)` to copy execution state into it. The signature changed in Rails 8.1.2:

- **Rails 7.2 – 8.1 stable (verified through 8.1.3)**: `share_with(Thread.current, except: live_streaming_excluded_keys)`. Reads from the parent **Thread's** `active_support_execution_state` accessor and dup's the result into the spawned thread's root fiber. Under `:fiber` isolation, `CurrentAttributes` and other ExecutionContext data live on `Fiber.current`'s accessor, not `Thread.current`'s. The parent Thread's accessor is empty. `share_with` copies an empty hash. Inside the streaming block, `Apartment::Current.tenant` is `nil`; queries route to the default-tenant pool. Silent cross-tenant data exposure.
- **Rails main (unreleased, future 8.2+)**: `share_with(IsolatedExecutionState.context, except: live_streaming_excluded_keys)`. Reads from the **current isolation context** — `Fiber.current` under `:fiber`. Under `:fiber`, the parent fiber's state copies through to the spawned thread's root fiber. The bug is fixed at the framework level once this refactor reaches a stable release.

Rails' upstream stance on `:fiber`-to-thread propagation in general (rails/rails#48279, closed wontfix): fiber apps must explicitly forward state across thread boundaries. The `share_with(context)` refactor on main is narrow to `Live`, not a generalization.

Apartment v4's supported Rails matrix is 7.2 through main. The bug exists on every currently-released Rails version (7.2, 8.0, 8.1.0–8.1.3) and must be fixed there. On Rails main Apartment's fix is redundant but harmless; once the `share_with(context)` change reaches a stable release, the around_action will no-op into Rails' own propagation.

### Why direct prepends on the spawn site don't work

The natural-looking fix is to capture the parent tenant on the request fiber, then `Apartment::Tenant.switch(captured) { ... }` somewhere inside `ActionController::Live#process` or `#new_controller_thread` to re-establish it on the spawned thread's root fiber.

This fails by construction. Trace through `Live#process` (pre-8.1.2 form):

```ruby
new_controller_thread do                    # block runs on spawned thread
  t2 = Thread.current
  locals.each { |k, v| t2[k] = v }
  ActiveSupport::IsolatedExecutionState.share_with(t1)  # OVERWRITES execution_state
  super(name)                                # action body runs with overwritten state
end
```

`share_with` does:

```ruby
old_state, context.active_support_execution_state = context.active_support_execution_state, copied_state
block.call
ensure
context.active_support_execution_state = old_state
```

A `Tenant.switch` ahead of `share_with` (whether via prepend on `new_controller_thread` or on the block it `yield`s to) sets state that `share_with` immediately overwrites. The action body sees the empty copy, not the captured tenant. The patch is a no-op.

The two ways out are:

1. Populate the channel `share_with` reads from before it runs. On `:fiber` that means assigning `Thread.current.active_support_execution_state = Fiber.current.active_support_execution_state` — pointer-mirroring across isolation scopes. Forbidden by Bucket 1 criterion 5.
2. Run the re-establishment **inside the spawned thread, after `share_with` has done its work, in a hook Rails calls from inside the action body**. That is what `around_action` does: callbacks run inside `process_action`, which runs inside `super(name)`, which runs inside `share_with`'s block, on the spawned thread.

### Bucket

1. Rails-created boundary; mechanical re-establishment; reachable from public Rails extension points (`ActiveSupport::Concern` composition + `around_action` + `Rack::Request#env`); silent failure mode; uses only the existing `Apartment::Current` channel in the spawned thread's root fiber; surface is two touchpoints (one concern, one elevator one-liner) that don't depend on `:nodoc:` API.

### Design

Three pieces:

**1. Elevator stash.** After the tenant is resolved, store the name on `request.env["apartment.tenant"]`. `env` is shared by reference between the request fiber and the spawned thread (same `Request` object reaches both), so it survives the boundary without needing to ride on `IsolatedExecutionState`.

```ruby
# lib/apartment/elevators/generic.rb
def call(env)
  request = Rack::Request.new(env)
  database = parse_tenant_name(request)
  if database
    env[Apartment::ENV_TENANT_KEY] = database  # NEW
    Apartment::Tenant.switch(database) { @app.call(env) }
  else
    @app.call(env)
  end
end
```

`Apartment::ENV_TENANT_KEY` is a constant (`"apartment.tenant"`) so applications and downstream gems read one canonical key.

**2. Concern that re-establishes inside the spawned thread.**

```ruby
# lib/apartment/concerns/live_tenancy.rb
module Apartment
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

The file lives in `lib/apartment/concerns/` to mirror the existing convention for `Apartment::Model` (`lib/apartment/concerns/model.rb` → `Apartment::Model`). Module name is top-level under `Apartment`.

`around_action` wraps the entire callback chain (before/after callbacks plus the action body), all of which run on the spawned thread's root fiber after `share_with` has executed. `Apartment::Tenant.switch` writes to `Apartment::Current.tenant`, which writes to `IsolatedExecutionState`, which under `:fiber` lands on the spawned thread's root fiber. In-model: the spawned thread's fiber gets its own tenant entry, scoped to the action's duration, with `ensure`-based cleanup that handles `live_thread_pool_executor`'s thread reuse.

**3. Auto-inject the concern into every `ActionController::Live` controller.**

`ActionController::Live` itself uses `extend ActiveSupport::Concern` (`actionpack/lib/action_controller/metal/live.rb`, all supported versions). Including a Concern into a Concern queues the inner Concern's `included do ... end` blocks to fire when the outer Concern is included in a class:

```ruby
# lib/apartment/railtie.rb (added)
initializer 'apartment.live_tenancy' do
  next unless defined?(ActionController::Base)  # apps without action_pack are skipped

  require "action_controller/metal/live"        # force-load (Live is autoloaded; defined? can be false)
  next if ActionController::Live.include?(Apartment::LiveTenancy)

  ActionController::Live.include(Apartment::LiveTenancy)
end
```

A named `initializer` (rather than `config.after_initialize`) — this hook does not depend on `Apartment.config`, and a named initializer runs earlier and gives a stable, name-addressable extension point if the include order ever needs to be constrained (`after: :something`). The explicit `require` is needed because `ActionController::Live` is autoloaded — `defined?(ActionController::Live)` returns falsy until something triggers the autoload, which doesn't happen by Apartment's initializer in apps that haven't yet referenced a Live controller. Requiring the file directly is idempotent and adds trivial memory overhead. The `include?` guard makes the operation idempotent under test reloads. Sibling pattern: the existing `initializer 'apartment.rescue_responses'` block.

The `:action_controller_live` load hook (`ActiveSupport.run_load_hooks(:action_controller_live, self)`) does not exist on Rails 7.2 / 8.0 / 8.1; it lands on Rails main and will ship in a future release. Using it instead of the unconditional initializer would skip the auto-include on exactly the versions where the fix is needed.

`Apartment::ENV_TENANT_KEY` is defined in `lib/apartment.rb` alongside the other top-level constants:

```ruby
# lib/apartment.rb
module Apartment
  ENV_TENANT_KEY = "apartment.tenant"
  # ...
end
```

Frozen string; one canonical reference shared by the elevator and the concern.

Custom-elevator backwards compatibility: apps that subclass `Apartment::Elevators::Generic` and override `#call` without calling `super` won't pick up the `env[Apartment::ENV_TENANT_KEY] = database` line. Their Live actions will continue to fail under `:fiber` on pre-8.1.2 Rails as they do today. The migration guide will surface this. The base-class one-line change is sufficient for the standard Subdomain / HostHash / Domain / FirstSubdomain elevators, all of which call `super` into `Generic#call`.

### Mechanism, plain

The elevator records which tenant the request belongs to in a place that crosses the Live spawn boundary by reference (`request.env`). Every Live controller gets an `around_action` that reads that record from inside the spawned thread and re-enters `Apartment::Tenant.switch` there. No state is shared across isolation scopes; the spawned thread's fiber gets its own tenant entry via the gem's normal write path.

### Behavior across Rails versions

| Rails | Native `share_with` propagates tenant under `:fiber`? | Apartment's around_action |
|---|---|---|
| 7.2 / 8.0 / 8.1.x (incl. 8.1.3) — every currently-released stable | No (reads `Thread.current`, empty under `:fiber`) | Sets tenant from `env`; the only thing that works |
| main (future 8.2+, when `share_with(context)` ships) | Yes (reads `Fiber.current` under `:fiber`) | Re-sets the same tenant; redundant no-op switch |

No version branching in code. The around_action is unconditional; once Rails ships the `share_with(context)` refactor in a stable release, the switch becomes a same-tenant re-entry with `ensure` cleanup.

### Behavior across isolation levels

| Isolation | Behavior |
|---|---|
| `:fiber` (v4 default) | The bug exists pre-8.1.2; the fix applies. |
| `:thread` (v3-compatible, opt-in) | Rails' `share_with(Thread.current)` already propagates state on all versions. The around_action's re-entry is a same-tenant no-op. |

No isolation-level guard needed.

### Trade-offs

- **Nested user threads / fibers inside the Live action.** `Thread.new { response.stream.write(...) }` or `Async {}` spawned inside the action body escape the `around_action` wrap. Same contract `:fiber` isolation imposes everywhere else: user-spawned threads/fibers must wrap themselves in `Apartment::Tenant.switch`. See `docs/upgrading-to-v4.md` § Async.
- **Elevator order.** Apps that disable Apartment's elevator and run their own tenant-resolution middleware must populate `env[Apartment::ENV_TENANT_KEY]` themselves for Live propagation to work. Documented in the migration guide.
- **App-defined `around_action` ordering.** `Apartment::LiveTenancy` registers its `around_action` when each Live controller class is composed, which places it *first* in the callback chain for that class. App-defined `around_action`s registered in `ApplicationController` (or any superclass loaded before the controller includes `ActionController::Live`) run earlier in the chain — they execute with the *default* tenant unless they wait for Apartment's wrap to enter first. Apps that hit the DB in such an outer `around_action` should declare it on the Live controller itself (so it nests inside `Apartment::LiveTenancy`'s wrap), or wrap the relevant body in `Apartment::Tenant.switch(request.env[Apartment::ENV_TENANT_KEY]) { ... }`. Documented in the migration guide.
- **Reused threads in `live_thread_pool_executor`.** `Apartment::Tenant.switch`'s block form `ensure`s teardown, so the spawned thread's root fiber state is restored on action exit; subsequent requests reusing the same worker thread start clean.

### Test coverage

- Unit spec for `Apartment::LiveTenancy`: included into a stub controller, the `around_action` reads `request.env`, calls `Apartment::Tenant.switch`, restores on raise.
- Unit spec confirming `ActionController::Live.include(Apartment::LiveTenancy)` queues the `included do` block such that a fresh controller class including `ActionController::Live` picks up the `around_action`.
- Integration spec in `spec/integration/v4/live_streaming_spec.rb` against a real `ActionController::Live` controller in the dummy app. Exercised under both `:thread` and `:fiber` isolation. Asserts queries inside `response.stream.write` route to the captured tenant, on the appraised Rails versions (7.2 / 8.0 / 8.1 / main). Includes a negative-control example that alias-swaps `Generic#call` to omit the env stash and asserts the streamed tenant falls back to the default — proving the around_action is causal, not coincidental.

### Documentation updates

- `docs/designs/apartment-v4.md` (#304 row in the limitations table): "Resolved via Bucket 1; see `docs/designs/rails-boundary-tenancy.md`."
- `docs/upgrading-to-v4.md` § Async: drop the "wrap the Live action in an explicit `Apartment::Tenant.switch`" instruction; replace with a one-liner pointing to the auto-propagation. The child-fiber-inside-Live caveat stays.
- `README.md` § Live streaming (new short section): note that Live controllers work out of the box on `:fiber`, and that nested user-spawned threads/fibers still need explicit switching.

## Worked example: ActiveStorage (#314)

### Problem

ActiveStorage assumes a global namespace: blob keys, attachment records, service mounts. Multi-tenancy needs storage paths scoped per tenant, blob and attachment models pinned, variant and preview jobs to inherit tenant context. The temporal piece (variant jobs) already rides on Bucket 1 infrastructure (Sidekiq/SolidQueue middleware) and is not blocked. The structural piece (paths, model graph, service configuration) needs sustained integration work.

### Bucket

3. The integration surface is large (blob key generation, attachment model, service configuration, route helpers, variant pipeline, signed-URL handling, direct-upload handlers, mirror services); each touchpoint churns across Rails minors; the integration is structural rather than temporal; it can ship independently. `kelder` (`rails-on-services/apartment#314`) has been offered as a starting point.

### Design

Companion gem `apartment-activestorage`. Core ships nothing new for this. Core's responsibility is to expose stable hooks (pinned-model registry, current-tenant accessor) that the companion uses. Adopters install the companion when they need it.

### Note

This row stops the recurring pull to absorb ActiveStorage into core. The temporal piece works today via Bucket 1 infrastructure; the structural piece is its own product with its own release cadence.
