# Multi-Tenancy at Rails-Created Execution Boundaries

## Purpose

Rails creates execution boundaries where tenant context can be lost: Rack requests, `ActionController::Live`'s spawned thread, ActionCable channel workers, Sidekiq/SolidQueue jobs, ActiveStorage variant pipelines. The gem has historically handled these case by case, sometimes introducing parallel state channels that contradict the v4 design.

This document defines the decision rubric for new (and re-evaluated) integrations. It answers: which boundaries does the gem own, by what mechanism, and what does it explicitly refuse.

## Rubric

Each Rails-created tenancy concern lands in exactly one bucket. Evaluate in order; first match wins.

### Bucket 1: auto-handle in core

All six conditions must hold:

1. The boundary is created by Rails or a closely-Rails-integrated subsystem (Sidekiq middleware, SolidQueue job runner), not by user code (`Thread.new`, `Async {}`, custom fibers).
2. The right policy is mechanical and tenant-agnostic: re-establish whatever the caller had.
3. Re-establishment is reachable from a stable extension point: a Rails load hook, `ActiveSupport::Concern` composition, `ActiveSupport::Notifications`, middleware, callback API, or a narrow prepend on a method whose signature has been stable across the supported Rails matrix.
4. The failure mode on doing nothing is silent (wrong-tenant queries, not raised exceptions).
5. The mechanism uses the gem's existing tenant channel (`Apartment::Current` via `CurrentAttributes`) — no parallel state stores like `Thread#thread_variable_set` (a thread-keyed channel separate from `ActiveSupport::IsolatedExecutionState`), no per-subsystem caches that compete with `Apartment::Current` for reads. When the patch backports a Rails fix that already exists on `main`, point the patch at the same data Rails' own propagation reads — this is using Rails' channel, not introducing one.
6. The integration surface is small: a handful of touchpoints with stable signatures, so per-Rails-version maintenance cost stays near zero.

The original draft of this rubric forbade "pointer-mirroring between thread-keyed and fiber-keyed storage" outright. That was overstated. Sharing a hash reference between two storage scopes is acceptable when:
- it's bounded in time (set, dispatch, restore in `ensure`)
- it exists to feed Rails' own propagation mechanism (e.g., `ActiveSupport::IsolatedExecutionState.share_with`) what that mechanism is looking for
- it mirrors the direction Rails is going (the worked example below explicitly backports `rails/rails#56902`)

What remains forbidden under criterion 5 is the PR #411 pattern: a *separate*, persistent storage channel keyed by Thread that the rest of the gem reads from in addition to `Apartment::Current`. That's a parallel state channel, not a temporary alignment.

### Bucket 2: provide a primitive, document a recipe

One or more of:

- Boundary is created by user code (`Thread.new`, `Async {}`, custom fiber). The user opted into the boundary; the user forwards state.
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

This matches Rails core's stated philosophy for user-spawned execution contexts (rafaelfranca on rails/rails#36646: *"If you want to pass down the value to a children thread you need to set the value again inside the thread."* byroot on rails/rails#48279: *"If you chose to use fibers as your app execution primitive, then fibers have to be isolated. If you create 'sub fibers' you have to explicitly forward whatever state it needs."*).

### Bucket 3: companion gem

One or more of:

- The integration surface is large: many Rails touchpoints, signatures that churn across Rails versions, transitive dependencies on subsystem internals.
- The integration is structural, not temporal: model graph, storage layer, route helpers, service configuration.
- The integration can ship independently without churning core API.

Mechanism: a separate gem (`apartment-<subsystem>`), versioned independently, declared as optional in core. Core exposes hooks the companion uses (pinned-model registry, current-tenant accessor); core does not host the companion's logic.

## Anti-patterns

The rubric exists in part to forbid these. They appear when it is bypassed.

- **Parallel state channels.** `Thread#thread_variable_set`, custom fiber storage, or per-subsystem stores that read or write tenant context outside `Apartment::Current`. The hot path (`lib/apartment/patches/connection_handling.rb:12-13`) reads one source: `Apartment::Current.tenant`. Adding fallback sources installs permanent branches and quiet ambiguity, and makes the subsystem whose channel got added special in a way the others are not. PR #411's mechanism is the canonical example.
- **Mechanism per subsystem.** If Live uses one storage scheme and ActionCable uses another and Sidekiq uses a third, contributors stop seeing the gem as having a coherent tenancy model. Different mechanisms are acceptable across buckets (1 vs 3); within a bucket they should converge on `Apartment::Tenant.switch` (or in temporary-mirror cases, on Rails' own propagation primitive).
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
| Generic ActiveJob (non-Sidekiq, non-SolidQueue) | 2, promotable to 1 | `Apartment::Jobs::ActiveJobExtension` opt-in |
| ActiveStorage | 3 | Out of core; companion gem path |

## Worked example: ActionController::Live (#304)

### Problem

`ActionController::Live#process` spawns an OS thread per streaming response and calls `ActiveSupport::IsolatedExecutionState.share_with(...)` to copy execution state into it. The signature has evolved:

- **Rails 7.2 – 8.1.x stable (verified through 8.1.3)**: `share_with(Thread.current, except: live_streaming_excluded_keys)`. Reads from the parent Thread's `active_support_execution_state` accessor and shallow-dup's into the spawned thread's root fiber. Under `:fiber` isolation, `CurrentAttributes` data lives on `Fiber.current.active_support_execution_state`, not `Thread.current`'s. The parent Thread's accessor is empty. `share_with` copies an empty hash. Inside the streaming block, `Apartment::Current.tenant` is `nil`; queries route to the default-tenant pool. Silent cross-tenant data exposure.
- **Rails main (rails/rails#56902, merged 2026-03-01)**: captures `IsolatedExecutionState.context` (= `Fiber.current` under `:fiber`) before the spawn and calls `share_with(context, except: ...)`. Reads from the current isolation context, so the parent fiber's state copies through correctly. Fixes the bug at the framework level — but the change has not landed in any stable Rails release as of 2026-05.

Per Rails' [maintenance policy](https://rubyonrails.org/maintenance):

- 8.1.x bug fixes through 2026-10-10 — backport request for #56902 is realistic.
- 8.0.x bug-fix window already closed (2026-05-07).
- 7.2.x is security-only.

Apartment v4 supports Rails 7.2+. The patch is required across the full supported matrix, not just as a wait-for-upstream stopgap.

### Backport, not invention

The fix already exists. `rails/rails#56902` is a 4-line change to `actionpack/lib/action_controller/metal/live.rb`:

```diff
 def process(name)
   t1 = Thread.current
   locals = t1.keys.map { |key| [key, t1[key]] }
+
+  # The IsolatedExecutionState context may be a Fiber, not a Thread
+  context = ActiveSupport::IsolatedExecutionState.context
@@
-    ActiveSupport::IsolatedExecutionState.share_with(t1, except: ...) do
+    ActiveSupport::IsolatedExecutionState.share_with(context, except: ...) do
       super(name)
```

We can't edit Rails source from inside a gem, but we can prepend `Live#process` and achieve the same effect: temporarily point `Thread.current.active_support_execution_state` at `Fiber.current.active_support_execution_state` before calling `super`, so `share_with(Thread.current, ...)` reads the right data. Restore the Thread's prior state in `ensure`.

```ruby
# lib/apartment/patches/live_tenant_propagation.rb
module Apartment
  module Patches
    module LiveTenantPropagation
      def process(name)
        return super unless ActiveSupport::IsolatedExecutionState.isolation_level == :fiber

        fiber_state = Fiber.current.active_support_execution_state
        return super if fiber_state.nil?

        previous_thread_state = Thread.current.active_support_execution_state
        Thread.current.active_support_execution_state = fiber_state
        begin
          super
        ensure
          Thread.current.active_support_execution_state = previous_thread_state
        end
      end
    end
  end
end
```

Wired via the Apartment Railtie:

```ruby
initializer 'apartment.live_tenancy' do
  next unless defined?(ActionController::Base)

  require 'action_controller/metal/live'
  require 'apartment/patches/live_tenant_propagation'
  next if ActionController::Live.include?(Apartment::Patches::LiveTenantPropagation)

  ActionController::Live.prepend(Apartment::Patches::LiveTenantPropagation)
end
```

`ActionController::Live` is a Module (a Concern). Prepending it adds our patch to the method-lookup chain of every class that subsequently includes `Live` — no opt-in, no per-controller wiring.

### Bucket

1. Rails-created boundary; mechanical re-establishment that propagates *all* CurrentAttributes (not just apartment's), matching what Rails' own `share_with(context)` does on main; no `:nodoc:` Rails API touched (`#process` is a public controller lifecycle method); silent failure mode; uses Rails' propagation channel rather than introducing a new one; one file (~25 lines including comments) plus a Railtie initializer.

### Why this is in-model, not a contradiction

The original framing rejected pointer-mirroring as a "model contradiction" — sharing data between Thread-keyed and Fiber-keyed storage when v4 chose Fiber isolation. That argument conflated two distinct mechanisms:

- **PR #411's `Thread#thread_variable_set` + fallback in `connection_pool`**: a parallel persistent channel. Read paths in the gem multiply; tenant identity has two sources of truth. This is the contradiction.
- **This patch**: temporarily makes `Thread.current.active_support_execution_state` point at the same hash `Fiber.current.active_support_execution_state` points at. There is still one channel — `IsolatedExecutionState` — and one source of truth. The mirror is bounded by `process(name)`'s call/`ensure` window. Outside that window, the Thread accessor is restored.

This is mechanically identical to what rails/rails#56902 does (capture the right context, pass it to share_with). It's not introducing a parallel channel; it's feeding Rails' existing channel the right pointer.

### Shared-Record-reference caveat

`share_with`'s `state.dup` is a shallow copy. The hash maps `:active_support_execution_context` → a `Record` object holding every `CurrentAttributes` instance. Both the parent fiber and the spawned thread's root fiber end up holding the same `Record` by reference; mutations from the spawned thread bleed into the parent.

This is a property of `share_with` itself, not introduced by the patch. djmb's commit message on rails/rails commit `61161df`: *"share_with does a shallow copy so changes from within the test streaming 'thread' can leak out — I think that's a fundamental flaw in how the Live module and thread state interact."* Rails has chosen to live with it; both `share_with(t1)` and `share_with(context)` share the property. Apartment's patch does not make this worse.

### Behavior across Rails versions

| Rails | Native `share_with` propagates under `:fiber`? | Apartment's patch |
|---|---|---|
| 7.2 / 8.0 / 8.1.x (incl. 8.1.3) — every currently-released stable | No (reads `Thread.current`, empty under `:fiber`) | Mirrors Fiber's state onto Thread's accessor; share_with finds it |
| main (future stable, when `share_with(context)` ships) | Yes (reads `Fiber.current` under `:fiber`) | Mirror is still applied; `share_with` reads from the Fiber's accessor and the Thread mirror is unused. Redundant; harmless |

The patch is also a no-op under `:thread` isolation (early return on `isolation_level == :fiber`).

### Trade-offs

- **Propagates all `CurrentAttributes`, not just apartment's tenant.** The mirror exposes the entire `:active_support_execution_context` hash. Apps with their own `Current.user`, `Current.account`, etc. get those propagated too. This matches `share_with(context)`'s behavior on rails main. If an app's `Current.foo` mutating from inside a streaming thread is undesirable, that's a Rails-level concern about `share_with`'s shallow-dup behavior, not specific to this patch.
- **Nested user threads / fibers inside the Live action.** `Thread.new { response.stream.write(...) }` or `Async {}` spawned inside the action body are not covered. The patch addresses Rails' internal Live thread spawn, not user-spawned ones. Same contract `:fiber` isolation imposes everywhere else — user-spawned execution contexts must wrap themselves in `Apartment::Tenant.switch`.
- **Reused threads in `live_thread_pool_executor`.** `share_with`'s own `ensure` restores the spawned thread's root-fiber state on action exit. Subsequent requests reusing the same worker thread start clean.

### Test coverage

- Unit spec for `Apartment::Patches::LiveTenantPropagation`: prepended into a stub controller, the `process` override mirrors Fiber state onto Thread, calls `super`, and restores on exit (both happy path and raise).
- Unit spec confirming the patch is a no-op under `:thread` isolation (Rails' own propagation already works there).
- Integration spec in `spec/integration/v4/live_streaming_spec.rb` against a real `ActionController::Live` controller in the dummy app. Asserts queries inside `response.stream.write` route to the captured tenant on PostgreSQL across the appraised Rails versions (7.2 / 8.0 / 8.1 / main). Includes a negative-control example that removes the prepend and confirms the streamed tenant falls back to the default — proving the patch is causal.
- Thread-pool reuse test: three consecutive `acme → widgets → acme` requests under `:fiber` show no state bleed.

### Documentation updates

- `docs/designs/apartment-v4.md`: update the `#304` row in the limitations table and the inline Live caveat to point at this rubric doc.
- `docs/upgrading-to-v4.md`: drop the "wrap Live actions in explicit `Apartment::Tenant.switch`" instruction. Replace with the auto-propagation note and the single caveat (user-spawned nested threads/fibers).
- `README.md` § Live streaming (new short section).

### Deletion path

Once `rails/rails#56902` lands in a stable Rails minimum that apartment supports, the patch becomes redundant. The current candidate: a Rails 8.1.x backport request. We file the request upstream; if accepted, apartment can guard the prepend behind a Rails version check and eventually delete the file.

## Worked example: ActiveStorage (#314)

### Problem

ActiveStorage assumes a global namespace: blob keys, attachment records, service mounts. Multi-tenancy needs storage paths scoped per tenant, blob and attachment models pinned, variant and preview jobs to inherit tenant context. The temporal piece (variant jobs) already rides on Bucket 1 infrastructure (Sidekiq/SolidQueue middleware) and is not blocked. The structural piece (paths, model graph, service configuration) needs sustained integration work.

### Bucket

3. The integration surface is large (blob key generation, attachment model, service configuration, route helpers, variant pipeline, signed-URL handling, direct-upload handlers, mirror services); each touchpoint churns across Rails minors; the integration is structural rather than temporal; it can ship independently. `kelder` (`rails-on-services/apartment#314`) has been offered as a starting point.

### Design

Companion gem `apartment-activestorage`. Core ships nothing new for this. Core's responsibility is to expose stable hooks (pinned-model registry, current-tenant accessor) that the companion uses. Adopters install the companion when they need it.

### Note

This row stops the recurring pull to absorb ActiveStorage into core. The temporal piece works today via Bucket 1 infrastructure; the structural piece is its own product with its own release cadence.
