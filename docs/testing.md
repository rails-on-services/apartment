# Testing with Apartment v4

This guide covers patterns for using Apartment in test suites: tenant discipline, the `switch` / `switch!` / `reset` distinction, cross-pool transaction visibility, and cleaning shared (default) tenant data between specs.

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

### `Tenant.assert_inside_tenant!`

```ruby
RSpec.configure do |config|
  config.before(:each) { Apartment::Tenant.assert_inside_tenant! }
end
```

Raises `Apartment::ApartmentError` when no tenant has been explicitly entered (i.e. `Apartment::Current.tenant` is `nil`).

The simplest way to keep `inside_tenant?` true across every example is **suite-level**: call `Tenant.switch!` once after suite bootstrap (see [Recommended baseline](#recommended-baseline-for-new-v4-apps)). Per-example `around { switch(name) { example.run } }` works too, but is only necessary when specs need different tenants via metadata; otherwise prefer the suite-level form to avoid lifecycle interactions with frameworks like test-prof's `let_it_be` / `before_all` (see footnote in the baseline section).

For richer failure messages, pass `message:`:

```ruby
Apartment::Tenant.assert_inside_tenant!(message: 'cross_tenant: true required for this spec')
```

`assert_inside_tenant!` reads `Current.tenant` directly, not `Tenant.current` — so it doesn't see the default-tenant fallback. That's the point: it answers "did this spec explicitly enter a tenant?", not "what tenant is effectively active?".

## `switch`, `switch!`, and `reset`

Three primitives, three scopes:

| Method | Form | Use case |
|---|---|---|
| `Tenant.switch(name) { ... }` | Block | Default; guaranteed cleanup via `ensure`. Use everywhere a block is natural. |
| `Tenant.switch!(name)` | No block | When the scope is structural (an `around` hook can't reach in), e.g. `before(:context)`, suite bootstrap. The caller is responsible for restoring tenant state. |
| `Tenant.reset` | No block | Returns to `default_tenant`. Bypasses `default_tenant_switch_allowed` — the documented path back to the default tenant. |

`switch!` is **not** deprecated in v4. It's correct for non-block scopes. The README's "prefer block-based switching" guidance applies when a block is natural; structural test hooks are exempt.

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

# spec/rails_helper.rb (after the suite bootstraps tenants)
Apartment::Tenant.switch!('test_tenant')

RSpec.configure do |c|
  c.before(:each) { Apartment::Tenant.assert_inside_tenant! }
end
```

This keeps the default schema for shared/pinned data (`Apartment::Model` + `pin_tenant`), enters an explicit tenant once at suite bootstrap so every example inherits it, and makes the "I forgot to switch" bug fail loudly at the first read of pinned data.

For suites that need **different tenants per example**, layer an `around` hook on top — driven by metadata so the default stays suite-level:

```ruby
RSpec.configure do |c|
  c.around do |example|
    tenants = Array(example.metadata[:tenants])
    next example.run if tenants.empty?

    Apartment::Tenant.with_tenants(*tenants) { example.run }
  end
end

# Per-spec opt-in:
RSpec.describe MyJob, tenants: %w[acme widgets] do
  # ...
end
```

> **Footnote on test-prof.** If your suite uses test-prof's `let_it_be` / `before_all`, prefer the suite-level `switch!` shown above over per-example `around { switch(...) { example.run } }`. `let_it_be` commits its setup data inside its own transaction; wrapping examples in an `around switch` can interact with the savepoint hierarchy in a way that DatabaseCleaner's rollback can't unwind cleanly when an example raises — producing a transaction-poisoning cascade where every subsequent example fails with `PG::InFailedSqlTransaction`. Suite-level `switch!` avoids this because there's no per-example switching wrapping `let_it_be` setup.

## Pool lifecycle in tests

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
