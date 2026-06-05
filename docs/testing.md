# Testing with Apartment v4

This guide covers patterns for using Apartment in test suites: tenant discipline, the `switch` / `switch!` / `reset` distinction, how rspec-rails resets tenant context between examples, cross-pool transaction visibility, and cleaning shared (default) tenant data between specs.

## Strict tenant discipline

Apartment's default behavior is permissive: `Apartment::Tenant.current` falls back to `default_tenant` when no tenant has been explicitly entered, and `Apartment::Tenant.switch(default_tenant) { ... }` works silently. This is convenient for app code but produces a class of test-suite bugs where ambient writes land in the default schema and tests don't notice.

Two opt-in tools tighten this up:

### `default_tenant_switch_allowed`

```ruby
Apartment.configure do |config|
  config.default_tenant_switch_allowed = false
end
```

When set to `false`, the block form `Apartment::Tenant.switch(default_tenant) { ... }` raises. `Apartment::Tenant.reset` and `Apartment::Tenant.switch!(default_tenant)` remain available — they're the documented "I genuinely intend to enter the default tenant" paths and bypass the guard.

The flag defaults to `true` for all strategies. New PostgreSQL `:schema` apps that want strict semantics from day one should opt in.

### `Tenant.assert_tenant_switched!`

```ruby
RSpec.configure do |config|
  config.before(:each) { Apartment::Tenant.assert_tenant_switched! }
end
```

Raises `Apartment::ApartmentError` when no tenant has been explicitly entered (i.e. `Apartment::Current.tenant` is `nil`).

Establish tenant context in a `before(:each)` hook — see [Recommended baseline](#recommended-baseline-for-new-v4-apps). It has to be `before(:each)`: not a one-time suite-level `switch!`, not a global `config.around`. rspec-rails resets `Apartment::Current` before every example, and only `before(:each)` runs after that reset — see [Tenant context is reset before every rspec-rails example](#tenant-context-is-reset-before-every-rspec-rails-example).

For richer failure messages, pass `message:`:

```ruby
Apartment::Tenant.assert_tenant_switched!(message: 'cross_tenant: true required for this spec')
```

`assert_tenant_switched!` reads `Current.tenant` directly, not `Tenant.current` — so it doesn't see the default-tenant fallback. That's the point: it answers "did this spec explicitly enter a tenant?", not "what tenant is effectively active?".

## `switch`, `switch!`, and `reset`

Three primitives, three scopes:

| Method | Form | Use case |
|---|---|---|
| `Tenant.switch(name) { ... }` | Block | Default; guaranteed cleanup via `ensure`. Use everywhere a block is natural. |
| `Tenant.switch!(name)` | No block | When no block can wrap the scope, e.g. `before(:each) { Tenant.switch!(name) }`, console or suite setup. The caller is responsible for restoring tenant state. |
| `Tenant.reset` | No block | Returns to `default_tenant`. Bypasses `default_tenant_switch_allowed` — the documented path back to the default tenant. |

`switch!` is **not** deprecated in v4. It's correct for non-block scopes. The README's "prefer block-based switching" guidance applies when a block is natural; structural test hooks are exempt.

## Tenant context is reset before every rspec-rails example

`Apartment::Current` is an `ActiveSupport::CurrentAttributes` subclass. Recent rspec-rails (8.x) mixes `ActiveSupport::CurrentAttributes::TestHelper` into every typed example group — `RailsExampleGroup`, which backs model, request, controller, system, and job specs. Its `before_setup` calls `ActiveSupport::CurrentAttributes.clear_all`, which resets **every** `CurrentAttributes` subclass — `Apartment::Current` included — at the start of each example. All four attributes (`tenant`, `previous_tenant`, `migrating`, `tenant_override`) return to `nil`.

That is correct framework behavior: it stops tenant context leaking between examples. But it dictates *where* tenant context can be established:

| Where tenant context is set | Survives to the example body? |
|---|---|
| Suite bootstrap (`rails_helper.rb` load time) | No — re-reset before every example |
| A global `config.around` hook | No — `config.around` wraps outside the reset |
| `before(:each)` / `config.before(:each)` | Yes — runs after the reset |
| An `around` defined inside an example group | Yes — but only for that group |

rspec-rails runs the reset (`before_setup`) inside a *group-level* `around` hook. A global `config.around` is the outermost hook in the stack, so whatever it sets is wiped by the reset before the body runs; a `before(:each)` runs after the reset and survives. (The gem's own suite is plain RSpec, not rspec-rails, so it never exercises this reset directly; `spec/unit/rspec_rails_lifecycle_spec.rb` is the dedicated regression guard.)

**The rule: establish tenant context in `before(:each)`, on every example.**

## Cross-pool transaction visibility

v4 uses pool-per-tenant connection routing. Each tenant gets its own connection pool, and a transaction held on one pool's connection is invisible to another pool's connection — even within the same test example.

This composes poorly with transactional fixture strategies (DatabaseCleaner `:transaction`, Rails' `use_transactional_fixtures`):

```ruby
let!(:integration) { create(:integration, instance_id: Instance.find_by(name: 'parents').id) }

it 'queues a job for each tenant' do
  expect { worker.perform }.to change { SomeJob.jobs.size }.by(1)
  # actually changes by 0 — the integration was committed to pool A's
  # transaction; the iterator runs in pool B and can't see uncommitted rows.
end
```

This is a structural property of pool-per-tenant, not a bug. Resolve it at the test-strategy layer:

- For specs that must do **cross-pool reads of writes from the same example**, switch off transactional fixtures and use a deletion strategy (`DatabaseCleaner.strategy = :deletion` or `:truncation`).
- For specs that **don't need cross-pool reads**, transactional fixtures are fine — keep them as the default for performance.

A common pattern is metadata-driven cleanup mode:

```ruby
RSpec.shared_context 'cross-tenant', cross_tenant: true do
  before do
    DatabaseCleaner.strategy = :deletion
    DatabaseCleaner.start
  end

  after { DatabaseCleaner.clean }
end

RSpec.configure do |c|
  c.include_context 'cross-tenant', cross_tenant: true
end

# Per-spec opt-in:
RSpec.describe MyJob, cross_tenant: true do
  # ...
end
```

Apartment intentionally does not provide a "shared connection across all pools in test mode" option. That would diverge test behavior from production pool semantics in a way that hides real bugs.

## Cleaning shared (default) tenant data between specs

Pinned models (declared with `Apartment::Model` + `pin_tenant`, or registered via the deprecated `excluded_models` shim) write to the default tenant's schema regardless of `Current.tenant`. With pool-per-tenant, those writes commit through whichever pool the model resolves to and may leak across examples if cleanup happens only in tenant pools.

A simple cleanup helper iterates pinned models and issues targeted deletes:

```ruby
# spec/support/clean_pinned_models.rb
module CleanPinnedModels
  def clean_pinned_models!
    Apartment.pinned_models.each do |klass|
      next unless klass.respond_to?(:delete_all)
      klass.delete_all
    rescue ActiveRecord::StatementInvalid
      # Table may not exist yet during early bootstrap; ignore.
    end
  end
end

RSpec.configure do |config|
  config.include CleanPinnedModels
  config.after(:each, :cleans_pinned) { clean_pinned_models! }
end
```

Apartment doesn't ship this helper because the right cleanup shape depends on the suite (transactional vs deletion strategy, fixture caching via test-prof, parallel CI shards). Copy the recipe and adapt.

## Recommended baseline for new v4 apps

```ruby
# config/initializers/apartment.rb
Apartment.configure do |config|
  config.tenant_strategy = :schema
  config.tenants_provider = -> { Tenant.pluck(:name) }
  config.default_tenant = 'public'
  config.default_tenant_switch_allowed = false
end
```

```ruby
# spec/rails_helper.rb
RSpec.configure do |c|
  # before(:each), not a one-time suite-level switch!: Apartment::Current is
  # reset before every example (see "Tenant context is reset ..." above), so
  # the tenant has to be re-entered each time.
  c.before(:each) { Apartment::Tenant.switch!('test_tenant') }
end
```

This keeps the default schema for shared/pinned data (`Apartment::Model` + `pin_tenant`) and enters an explicit tenant for every example.

If you would rather have each spec enter its own tenant — so a forgotten switch fails loudly — drop the `switch!` and assert instead:

```ruby
c.before(:each) { Apartment::Tenant.assert_tenant_switched! }
```

Each spec is then responsible for switching, in its own `before(:each)` or in an `around` defined *inside* the example group. A group-level `around` survives the reset; a global `config.around` does not.

For **different tenants per example**, drive the switch from metadata — still `before(:each)`:

```ruby
RSpec.configure do |c|
  c.before(:each) do |example|
    tenant = example.metadata[:tenant]
    Apartment::Tenant.switch!(tenant) if tenant
  end
end

# Per-spec opt-in:
RSpec.describe MyJob, tenant: 'acme' do
  # ...
end
```

To scope `Apartment::Tenant.each` to a set of tenants for an example, set the iteration override in `before(:each)` — `with_tenants` is block-form and wraps a code path, not an example:

```ruby
c.before(:each) do |example|
  names = Array(example.metadata[:tenants]).map(&:to_s).freeze
  Apartment::Current.tenant_override = names unless names.empty?
end
```

> **Footnote on test-prof.** `let_it_be` / `before_all` run setup in `before(:context)` — outside the per-example `Apartment::Current` reset. If those blocks create tenant-scoped data, establish tenant context for them explicitly (a `before(:context)` / `before_all` that calls `Apartment::Tenant.switch!`). Do not wrap examples in an `around switch` to compensate: a global `config.around` is defeated by the reset above, and an `around` wrapping `let_it_be`'s committed setup can also poison the savepoint hierarchy into a `PG::InFailedSqlTransaction` cascade.

## Pool lifecycle in tests

### The invariant

v3's test-suite pain was a **variable problem**: at any given moment, which `search_path` is current? Tests that crossed tenants had to reason about an in-flight setting and reset it carefully. v4 swapped that for a **resource lifecycle problem**: does the connection pool that fixtures enrolled for rollback still exist with the same object identity? Rails' transactional fixtures pin pools by object reference (`ConnectionPool#pin_connection!`) and unwind them by walking that same reference at teardown. Discard a pinned pool mid-suite and the recreated one has a fresh `object_id`; the fixture transaction never enrolled it; rollback misses its writes.

The rule, in one line: **pool lifecycle changes during fixture-transaction ownership are a violation.** Any Apartment API that discards or replaces a pool must refuse to do so while Rails owns it. `Apartment::PoolReaper` already implements this for eviction (see the reaper subsection below); `Apartment.reset_tenant_pools!` extends it to the explicit-reset path.

The failure-class inventory, rejected alternatives, and ongoing investigation live in `docs/designs/fixture-pool-lifecycle.md`.

### `Apartment.reset_tenant_pools!` in test env

In `Rails.env.test?`, `Apartment.reset_tenant_pools!` raises `Apartment::FixtureLifecycleViolation` when any tenant pool in `Apartment.pool_manager` is currently pinned by fixtures. Outside test env, semantics are unchanged.

```text
Apartment::FixtureLifecycleViolation: reset_tenant_pools! called while pool
'acme:writing' is pinned by transactional fixtures. To cycle pools mid-suite,
disable transactional fixtures for this test (use_transactional_tests = false)
and clean up by deletion. See docs/testing.md.
```

The guard fires when a tenant pool already exists in the pool manager AND has been pinned. The common bootstrap path — `Apartment::TestFixtures` calling `reset_tenant_pools!` before `setup_shared_connection_pool` runs, no tenant pools tracked yet — is unaffected. If you hit the violation, the call is happening at the wrong time, not from the wrong place.

What to do instead, depending on the call site:

- **Cleanup hook in a cross-tenant spec** (the most common cause): the spec needs to cycle pools mid-suite. See ["Cycling pools mid-suite"](#cycling-pools-mid-suite) below for the documented opt-out recipe.
- **Suite bootstrap or teardown**: move the call out of any `before(:each)` / `after(:each)` that runs under transactional fixtures. `before(:suite)` and `after(:suite)` are safe; `before(:all)` and `after(:all)` are safe if `use_transactional_tests` is the default (Rails enrols the fixture tx per-example, not per-group).
- **Production cleanup script that imports Rails**: not a real call site, but if it shows up, ensure the script runs outside `Rails.env.test?` or call the pool-manager's `clear` directly.

### Pool reaper

`Apartment::PoolReaper` evicts idle and excess tenant pools on a background timer. In production it bounds memory under high tenant counts; in test suites it's typically a liability — short runs, few tenants, no memory pressure, and an eviction mid-example can orphan transactional-fixture state. **The Railtie stops the reaper automatically when `Rails.env.test?`.** A suite that genuinely needs eviction (long-running parallel tenant churn, large fixtures) can opt back in:

```ruby
# spec/rails_helper.rb
Apartment.pool_reaper&.start
```

The reaper is also defensive against transactional state when it does run. Two guards block eviction of a candidate pool:

- **Pinned pools** (`ConnectionPool#pin_connection!`) — the path Rails' transactional fixtures use, plus the lazy-creation case where the `!connection.active_record` subscriber pins after-the-fact.
- **In-use pools** — at least one connection is leased (`Connection#in_use?`) or holds an open transaction (`Connection#open_transactions > 0`). Covers any consumer that opened a transaction outside the fixture machinery: long migrations, batch jobs, an explicit `ActiveRecord::Base.transaction` block.

Both skip paths emit `skip_evict.apartment` notifications with `reason:` `:pinned` or `:in_use` (the `:in_use` payload includes `busy_connections` and `open_transactions`). If a tenant key shows up repeatedly in `skip_evict` events over time, that's the signal for a leaked connection or forgotten transaction — fix the leak, don't tune the reaper.

Both guards are best-effort: the reaper checks the pool state and then removes it as separate steps, so a pool can become pinned or in-use in the sub-millisecond window between. The cost of an unlucky race is a test-isolation failure (dirty fixture state, rows leaking between examples), not production data corruption.

Two narrow cases the in-use guard does **not** cover:

- A server-side cursor (`WITH HOLD`, certain `COPY` paths) holding server state without an open transaction. ActiveRecord exposes no public predicate for this; rare in typical Rails code.
- A pool whose connections have all been returned but a query-cache or prepared-statement cache remains warm — correctly evictable; the next access rebuilds both.

When LRU pressure can't reach `max_total_connections` because too many pools are protected, the reaper emits `cap_unmet.apartment` instead of forcing eviction. The cap is best-effort under active workload — if you see it firing, check for the same leak signature in `skip_evict`.

### Cycling pools mid-suite

A small set of specs legitimately needs to cycle tenant pools — cross-tenant cleanup suites that drop and recreate tenants per example, integration tests that exercise `Apartment::Tenant.create` / `destroy` directly, or harness tests for the pool manager itself. Inside transactional fixtures, this trips `FixtureLifecycleViolation`. The opt-out is to take the offending example (or its enclosing TestCase / `describe` block) out of fixture transactions and clean up by deletion instead.

Opting out at the class / group level uses Rails' supported primitive:

```ruby
RSpec.describe 'tenant lifecycle', cross_tenant: true do
  self.use_transactional_tests = false
  # … examples that switch, create, and destroy tenants freely
end
```

```ruby
# Minitest equivalent — per test method or per class
class TenantLifecycleTest < ActiveSupport::TestCase
  self.use_transactional_tests = false
  # …
end

class MixedTest < ActiveSupport::TestCase
  uses_transaction :test_recreates_pool   # only this method opts out
  # …
end
```

With `use_transactional_tests = false`, no pool gets pinned and `Apartment.reset_tenant_pools!` runs without tripping the guard. The cost: nothing rolls back automatically — neither tenant data nor pinned-model writes to the default schema. You own the cleanup.

A pragmatic cleanup recipe for the opted-out group:

```ruby
RSpec.shared_context 'cycles pools', cross_tenant: true do
  before do
    DatabaseCleaner.strategy = :deletion   # :truncation also works; :transaction does not
    DatabaseCleaner.start
  end

  after do
    DatabaseCleaner.clean
    clean_pinned_models!                   # see "Cleaning shared (default) tenant data" above
    Apartment.reset_tenant_pools!          # now safe — no pins left
  end
end

RSpec.configure { |c| c.include_context 'cycles pools', cross_tenant: true }
```

Three notes on the recipe:

- **Cleanup scope is yours.** `:deletion` cleans tables in the default and tenant schemas reached via the same handler. Pinned-model writes to the primary schema are *not* covered by tenant-pool cleanup alone — chain `clean_pinned_models!` (or the equivalent for your suite). The pinned-model helper is documented above.
- **Reset pools last.** Calling `reset_tenant_pools!` before deletion would leave tenant rows behind in the DB; calling it after means the next example starts with no live pools and a clean slate.
- **Inheritance is sticky.** `self.use_transactional_tests = false` at the group level applies to nested describes too. Prefer narrow opt-in (`describe '…', cross_tenant: true do`) over flipping it globally; the metadata makes the opt-out grep-able.

Apartment does not ship an `Apartment::Test::CrossTenant` module. The mechanism above is Rails-native, the cleanup recipe is sensitive to the suite's other tools (DatabaseCleaner, test-prof, factory caching), and the cost of getting it wrong is a noisy `FixtureLifecycleViolation`, not silent data loss. Copy the recipe and adapt.
