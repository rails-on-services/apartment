# TestFixtures Compatibility Patch

## Problem

Rails' `ActiveRecord::TestFixtures#setup_shared_connection_pool` iterates all shards registered in the ConnectionHandler and assumes every shard has a `:writing` pool_config. Apartment registers tenant pools under role-specific custom shard keys (e.g., shard `:apartment_acme:reading` under role `:reading`) that may not have a `:writing` counterpart for the same shard.

When the fixture setup encounters such a shard, `writing_pool_config` resolves to nil, and `set_pool_config(role, shard, nil)` raises `ArgumentError`.

### The Rails assumption

From `ActiveRecord::TestFixtures#setup_shared_connection_pool` ([v8.0.3 source](https://github.com/rails/rails/blob/v8.0.3/activerecord/lib/active_record/test_fixtures.rb)):

```ruby
def setup_shared_connection_pool
  handler = ActiveRecord::Base.connection_handler
  handler.connection_pool_names.each do |name|
    pool_manager = handler.send(:connection_name_to_pool_manager)[name]
    pool_manager.shard_names.each do |shard_name|
      writing_pool_config = pool_manager.get_pool_config(ActiveRecord.writing_role, shard_name)
      @saved_pool_configs[name][shard_name] ||= {}
      pool_manager.role_names.each do |role|
        next unless pool_config = pool_manager.get_pool_config(role, shard_name)
        next if pool_config == writing_pool_config
        @saved_pool_configs[name][shard_name][role] = pool_config
        pool_manager.set_pool_config(role, shard_name, writing_pool_config) # nil when no :writing entry
      end
    end
  end
end
```

`shard_names` returns all unique shards across all roles. If apartment registered shard `:apartment_acme:reading` under role `:reading` only, the `:writing` lookup for that shard returns nil. The `next unless` guard passes (the `:reading` entry exists), and `set_pool_config` receives nil as the pool_config argument.

### When it surfaces

Two distinct triggers produce the same `ArgumentError`:

**Trigger A — stale pools from prior tests (addressed in initial PR #379)**

1. A `before(:all)` block (or prior test) triggers the elevator, creating a tenant pool under a non-writing role (e.g., `connected_to(role: :reading)` during a request)
2. A subsequent test example's fixture setup (Minitest's `before_setup`, or the equivalent RSpec fixture lifecycle via `RSpec::Rails::FixtureSupport`) calls `setup_transactional_fixtures` → `setup_shared_connection_pool`
3. The fixture machinery discovers the apartment shard, tries to map it across roles, raises `ArgumentError`

**Trigger B — subscriber re-entry with live pools (discovered post-merge)**

1. Initial `setup_shared_connection_pool` call runs cleanup, calls `super` — clean, no apartment pools
2. `setup_transactional_fixtures` subscribes to `!connection.active_record`
3. During the test, the elevator switches tenants → `ConnectionHandling#connection_pool` → `establish_connection` fires `!connection.active_record` **synchronously** while the pool_config is already stored in Rails' PoolManager
4. Subscriber fires → calls `setup_shared_connection_pool` again
5. Guard is set → cleanup skipped → `super` runs → finds the apartment shard that was just registered → `writing_pool_config` is nil → `ArgumentError`

The key insight: `establish_connection` stores the pool_config in Rails' PoolManager via `set_pool_config` **before** firing the notification (the notification wraps `pool_config.pool` inside the `instrument` block). By the time the subscriber calls `setup_shared_connection_pool`, the apartment shard is visible to `shard_names` but has no `:writing` counterpart.

The writing role is unaffected because `writing_pool_config` is non-nil for shards created under `:writing`, making the `next if pool_config == writing_pool_config` guard short-circuit correctly.

## Design

### Approach: auto-wire via Railtie

Prepend a module (via `ActiveSupport.on_load(:active_record_fixtures)`) on the class that includes `ActiveRecord::TestFixtures`, overriding `setup_shared_connection_pool` to deregister apartment's tenant pools before the fixture machinery iterates them. Pools are lazy; they rebuild on the next `connection_pool` call.

**Why auto-wire, not opt-in**: `activerecord-tenanted` (Basecamp) sets the precedent for auto-wiring fixture integration via Railtie: it uses the same `:active_record_fixtures` hook point to prepend a module that adjusts fixture behavior for tenant pools (overriding `transactional_tests_for_pool?`, not `setup_shared_connection_pool` -- different fix, same hook and delivery mechanism). The incompatibility is a framework-level invariant violation (Rails assumes every shard has a `:writing` pool_config), not an application-level concern. Users shouldn't need to know that `setup_shared_connection_pool` cross-joins shards and roles.

**Escape hatch**: `config.test_fixture_cleanup` defaults to `true`. Set to `false` to disable the auto-wire.

### Components

#### 1. `Apartment::TestFixtures` module

New file: `lib/apartment/test_fixtures.rb`

Prepended on the class that includes `ActiveRecord::TestFixtures` (see Railtie wiring below for why). Overrides the private `setup_shared_connection_pool` method:

```ruby
module Apartment
  module TestFixtures
    private

    def setup_shared_connection_pool
      return if @apartment_fixtures_cleaned

      @apartment_fixtures_cleaned = true
      Apartment.reset_tenant_pools! if Apartment.pool_manager
      super
    end

    def teardown_shared_connection_pool
      @apartment_fixtures_cleaned = false
      super
    end
  end
end
```

The guard serves two purposes:

1. **First call** (guard unset): cleanup runs, `super` runs against a clean ConnectionHandler. This handles Trigger A (stale pools from prior tests).

2. **Subscriber re-entry** (guard set): `return` skips both cleanup AND `super`. This handles Trigger B. Apartment pools registered mid-test must NOT pass through `setup_shared_connection_pool`; they violate Rails' invariant that every shard has a `:writing` pool_config.

**Why skipping `super` on re-entry is safe**: The subscriber (in `setup_transactional_fixtures`) runs its own logic after `setup_shared_connection_pool` returns — it still pins the new connection and leases it, regardless of whether the shared pool config swapping ran. The shared pool config swap is only needed once at initial setup; its purpose is to make `:reading` connections share the `:writing` pool so reads can see uncommitted fixture data within the transaction. Apartment pools are entirely separate tenant connections, not reading replicas of the default `:writing` pool, so the swap is semantically wrong for them anyway.

**Edge case — non-apartment connections mid-test**: If a legitimate non-apartment connection is established mid-test (e.g., a model's `connects_to` for a separate database fires lazily), skipping `super` means its `:reading` role won't be swapped to share `:writing`. In practice, all database connections are established during app boot, before the first test runs. If this becomes a real issue, the fix would be to replace `super` with apartment-aware iteration that skips shards with the `shard_key_prefix` prefix (see Alternatives).

Three operations on first call:
- `deregister_all_tenant_pools` (via `reset_tenant_pools!`) — removes apartment shards from AR's ConnectionHandler so `setup_shared_connection_pool` doesn't iterate them
- `pool_manager.clear` — clears apartment's internal pool cache (pools rebuild lazily on next `connection_pool` call)
- `Current.reset` — clears tenant context so no stale tenant leaks into fixture setup

The teardown override resets the guard for the next example's setup cycle.

#### 2. Railtie wiring

Addition to `lib/apartment/railtie.rb`, inside the existing Railtie class:

```ruby
if Rails.env.test?
  ActiveSupport.on_load(:active_record_fixtures) do
    if Apartment.config&.test_fixture_cleanup
      require 'apartment/test_fixtures'
      prepend Apartment::TestFixtures
    end
  end
end
```

**Boot order assumption**: `Apartment.configure` must run before the test framework includes `ActiveRecord::TestFixtures` (which fires the hook). This holds for standard Rails boot: initializers run before the test suite loads. If `Apartment.config` is nil at hook time, the prepend is silently skipped. Apps that defer `Apartment.configure` past test framework load would need to prepend manually.

The `:active_record_fixtures` hook fires via `ActiveSupport.run_load_hooks(:active_record_fixtures, self)` inside `TestFixtures`' `included` block. `self` there is the class that included `ActiveRecord::TestFixtures` (e.g., `ActiveSupport::TestCase` for Minitest, or the RSpec example group base class via `RSpec::Rails::FixtureSupport`). The `prepend` therefore targets that class, not the `ActiveRecord::TestFixtures` module itself. Functionally equivalent: the overridden method sits above the mixed-in `setup_shared_connection_pool` in the method resolution chain.

This applies to both Minitest and RSpec: `RSpec::Rails::FixtureSupport` includes `ActiveRecord::TestFixtures`, which fires the same hook.

#### 3. Config attribute

Addition to `lib/apartment/config.rb`:

Add `:test_fixture_cleanup` to `attr_accessor` and set `@test_fixture_cleanup = true` in `initialize`. Boolean validation in `validate!` ensures misconfiguration fails fast.

### Scope boundaries

This patch does NOT:

- Affect non-test environments — the `on_load` hook only fires when `Rails.env.test?` is true.
- Change pool key format or registration strategy — custom shard keys remain; the fix is cleanup before the fixture machinery iterates them.
- Interfere with the `!connection.active_record` subscriber in `setup_transactional_fixtures` — subscriber-triggered re-entries return early, but the subscriber's own pin/lease logic still executes normally. Apartment pools get pinned and leased; they just skip the shared pool config swap.

**Residual risk**: `deregister_all_tenant_pools` enumerates `Apartment.pool_manager.stats[:tenants]`. A pool that exists in the ConnectionHandler but not in apartment's PoolManager would be missed, and the first `super` could still crash. In practice this requires a code path that registers apartment-prefixed shards in the ConnectionHandler without going through `ConnectionHandling#connection_pool` → `fetch_or_create`, which is the only registration path. If this surfaces, the fix is to extend cleanup to enumerate handler shards matching the `shard_key_prefix` directly.

### Interaction with other gems

Gems that also prepend on `:active_record_fixtures` (e.g., `activerecord-tenanted`) share the prepend chain. The last gem to prepend runs first (outermost in MRO). If Apartment prepends last, its cleanup runs before other gems' `setup_shared_connection_pool` overrides, and they see a clean handler. If another gem prepends after Apartment, their override runs first and may encounter apartment shards before cleanup. In practice this is unlikely to conflict: `activerecord-tenanted`'s override targets `transactional_tests_for_pool?` (orthogonal method), not `setup_shared_connection_pool`. If a real conflict surfaces, prepend order can be controlled by Railtie load order or by having the app explicitly re-prepend.

## Testing

### Unit test: `spec/unit/test_fixtures_spec.rb`

Exercises the scenario directly:

1. Register a tenant pool under `:reading` only (simulating `connected_to(role: :reading)` + elevator)
2. Verify that calling `setup_shared_connection_pool` without the patch raises `ArgumentError`
3. Verify that with the patch prepended, `setup_shared_connection_pool` succeeds
4. Verify pools are lazily recreated after cleanup
5. Verify the guard prevents re-entrant calls from iterating apartment shards (simulating the `!connection.active_record` subscriber path — Trigger B). Specifically: first call cleans up and runs `super`, then a pool is added mid-test, second call returns early without calling `super` or crashing
6. Verify `teardown_shared_connection_pool` resets the guard for the next cycle
7. Verify `config.test_fixture_cleanup = false` prevents the prepend

### Integration consideration

The gem's own integration tests use RSpec with a ConnectionHandler swap per example; fixture support is not loaded, so `setup_shared_connection_pool` doesn't fire in the gem's test suite. However, both Minitest and RSpec exercise the same `ActiveRecord::TestFixtures` code path in downstream apps. The real proof is in apps that use transactional fixtures with `before(:all)` request blocks. A targeted unit test that exercises the Rails method directly is sufficient for the gem.

## Cross-Tenant Transactional Fixture Limitation

### The constraint

v4 uses a separate connection pool (and physical connection) per tenant. Rails' transactional fixtures wrap each test in an uncommitted transaction on one connection. Records inserted via one pool's connection are invisible to another pool's connection within those uncommitted transactions.

This is architectural: pool-per-tenant and single-connection transactional fixtures are fundamentally incompatible for cross-tenant operations. v3 avoided this by using `SET search_path` on a single shared connection; v4 intentionally eliminated runtime search_path mutation in favor of immutable per-pool config.

### What works

**Single-tenant specs**: Tests that operate entirely within one tenant context use one pool, one connection, one transaction. Transactional fixtures work normally.

**Default-tenant specs**: Tests that never switch tenants use the default pool. Transactional fixtures work normally.

### What breaks

**Cross-tenant specs**: Any test where records are written on one pool and read on another. The common pattern:

1. Spec's `around` block switches to tenant 'parents' → creates/uses the tenant pool (connection A)
2. Record created inside the test → inserted on connection A, inside an uncommitted transaction
3. Controller calls `switch_to_public_tenant { Model.find(id) }` → `Current.tenant = 'public'` → `ConnectionHandling` returns the default pool (connection B)
4. Connection B can't see connection A's uncommitted transaction → `RecordNotFound`

This affects ALL cross-tenant operations in tests, including pinned models. Qualified table names (`public.global_cohorts`) fix schema name resolution (which `schema.table` to query), not transaction visibility across connections. A pinned model INSERT on connection A is invisible to connection B regardless of table name qualification.

**Why pinned models don't help here**: PR #374 made pinned models share the tenant pool (not the default pool) so that pinned writes participate in the same transaction as tenant writes. This is correct for production. But when `switch_to_public_tenant` changes `Current.tenant` to the default, `ConnectionHandling` returns the default pool (line 17: `return super if tenant.to_s == cfg.default_tenant.to_s`). The pinned model read goes through a different connection than the pinned model write.

### Recommended testing strategy

Disable transactional tests for cross-tenant spec groups and use explicit cleanup:

**RSpec:**

```ruby
# spec/requests/platform_controller_spec.rb
RSpec.describe PlatformController, type: :request do
  # Cross-tenant: controller uses switch_to_public_tenant internally
  self.use_transactional_tests = false

  after { DatabaseCleaner.clean_with(:truncation) }

  # ... specs that create records in one tenant and query in another
end
```

**Minitest:**

```ruby
class PlatformControllerTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false

  teardown { DatabaseCleaner.clean_with(:truncation) }
end
```

**What to pair with `use_transactional_tests = false`:**

- **Cleanup**: Truncation via DatabaseCleaner, or manual `after` hooks. Without transactional rollback, records persist across examples.
- **Order independence**: Non-transactional examples are flakier under random order unless cleanup is explicit.
- **Speed**: Truncation is slower than transactional rollback. Scope the override to the specific context that needs it, not the entire suite.

### Scope

This limitation applies only to PostgreSQL schema strategy. Database-per-tenant strategies (PG database, MySQL, SQLite) use physically separate databases; cross-tenant transactional isolation is architecturally impossible there regardless, and those apps already use truncation or per-tenant test databases.

### Alternatives considered for this limitation

**Test-mode `SET search_path` switching**: In test environment, `ConnectionHandling#connection_pool` returns the default pool for all tenants and switches via `SET search_path TO ...` on the shared connection. Rejected: re-introduces the runtime search_path mutation that v4 intentionally eliminated. The pool-per-tenant architecture is v4's core design decision; undermining it for tests means the test environment no longer validates the production code path.

**Always route pinned models through default pool**: Change `ConnectionHandling` so pinned models use `super` (default pool) regardless of `shared_pinned_connection?`. Rejected: breaks the transactional integrity that PR #374 established — pinned writes would no longer participate in the same transaction as tenant writes. The correct fix is at the test strategy level, not the connection routing level.

## Alternatives considered

### A. Register shards for ALL roles when creating for one role

Apartment would register a pool_config for every known role when creating a tenant pool, ensuring `setup_shared_connection_pool` always finds a `:writing` entry.

**Rejected**: Creates unnecessary pools, complicates pool lifecycle (eviction, drop), and couples pool creation to the set of roles registered at that moment. A role registered later would still be missed.

### B. Opt-in test helper (`include Apartment::TestHelper`)

Users add the include to their test base class manually.

**Rejected**: The incompatibility is invisible until it fails. Users can't reasonably predict that `setup_shared_connection_pool` iterates custom shards. `activerecord-tenanted` sets the precedent for auto-wiring this class of fix.

### C. Use `:default` shard instead of custom shard keys

Overwrite the `(:reading, :default)` pool entry with tenant-specific config.

**Rejected**: Breaks the clean namespace separation apartment uses. Clobbers the default reading pool, complicating cleanup and PoolManager tracking. Would require reworking the existing pool key architecture.

### D. Replace `super` with apartment-aware iteration

Copy Rails' `setup_shared_connection_pool` logic but skip shards whose name starts with the `shard_key_prefix`. This would allow `super`-equivalent behavior on every call (including subscriber re-entry) without crashing on apartment shards, and would handle the edge case of non-apartment connections established mid-test.

**Deferred**: Copies Rails internals, creating a maintenance burden across Rails versions. The current guard-based approach handles all known production scenarios. If the mid-test non-apartment connection edge case surfaces in practice, this becomes the right escalation path.
