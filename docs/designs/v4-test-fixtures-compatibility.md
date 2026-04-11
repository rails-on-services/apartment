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

1. A `before(:all)` block (or prior test) triggers the elevator, creating a tenant pool under a non-writing role (e.g., `connected_to(role: :reading)` during a request)
2. A subsequent test example's fixture setup (Minitest's `before_setup`, or the equivalent RSpec fixture lifecycle via `RSpec::Rails::FixtureSupport`) calls `setup_transactional_fixtures` -> `setup_shared_connection_pool`
3. The fixture machinery discovers the apartment shard, tries to map it across roles, raises `ArgumentError`

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
      unless @apartment_fixtures_cleaned
        @apartment_fixtures_cleaned = true
        if Apartment.pool_manager
          Apartment.send(:deregister_all_tenant_pools)
          Apartment.pool_manager.clear
          Apartment::Current.reset
        end
      end
      super
    end

    def teardown_shared_connection_pool
      @apartment_fixtures_cleaned = false
      super
    end
  end
end
```

The cleanup runs once per setup/teardown cycle, guarded by `@apartment_fixtures_cleaned`. This prevents re-entry: `setup_transactional_fixtures` registers a `!connection.active_record` notification subscriber that calls `setup_shared_connection_pool` again whenever a new pool is established mid-example. Without the guard, tenant pools created during a test (via `establish_connection` inside the `ConnectionHandling` patch) would trigger the subscriber, which would deregister the pool that was just registered -- leaving it in apartment's PoolManager but orphaned from the ConnectionHandler.

Three operations on first call:
- `deregister_all_tenant_pools` -- removes apartment shards from AR's ConnectionHandler so `setup_shared_connection_pool` doesn't iterate them
- `pool_manager.clear` -- clears apartment's internal pool cache (pools rebuild lazily on next `connection_pool` call)
- `Current.reset` -- clears tenant context so no stale tenant leaks into fixture setup

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

Add `:test_fixture_cleanup` to `attr_accessor` and set `@test_fixture_cleanup = true` in `initialize`. No validation needed; boolean with a safe default.

### Scope boundaries

This patch does NOT:

- Affect non-test environments -- the `on_load` hook only fires when `Rails.env.test?` is true.
- Change pool key format or registration strategy -- custom shard keys remain; the fix is cleanup before the fixture machinery iterates them.
- Interfere with the `!connection.active_record` subscriber in `setup_transactional_fixtures` -- the `@apartment_fixtures_cleaned` guard ensures cleanup runs only once per setup cycle; subscriber-triggered re-entries of `setup_shared_connection_pool` pass through to `super` without cleanup.

### Interaction with other gems

Gems that also prepend on `:active_record_fixtures` (e.g., `activerecord-tenanted`) share the prepend chain. The last gem to prepend runs first (outermost in MRO). If Apartment prepends last, its cleanup runs before other gems' `setup_shared_connection_pool` overrides, and they see a clean handler. If another gem prepends after Apartment, their override runs first and may encounter apartment shards before cleanup. In practice this is unlikely to conflict: `activerecord-tenanted`'s override targets `transactional_tests_for_pool?` (orthogonal method), not `setup_shared_connection_pool`. If a real conflict surfaces, prepend order can be controlled by Railtie load order or by having the app explicitly re-prepend.

## Testing

### Unit test: `spec/unit/test_fixtures_spec.rb`

Exercises the scenario directly:

1. Register a tenant pool under `:reading` only (simulating `connected_to(role: :reading)` + elevator)
2. Verify that calling `setup_shared_connection_pool` without the patch raises `ArgumentError`
3. Verify that with the patch prepended, `setup_shared_connection_pool` succeeds
4. Verify pools are lazily recreated after cleanup
5. Verify the guard prevents cleanup on re-entrant calls (simulating the `!connection.active_record` subscriber path)
6. Verify `teardown_shared_connection_pool` resets the guard for the next cycle
7. Verify `config.test_fixture_cleanup = false` prevents the prepend

### Integration consideration

The gem's own integration tests use RSpec with a ConnectionHandler swap per example; fixture support is not loaded, so `setup_shared_connection_pool` doesn't fire in the gem's test suite. However, both Minitest and RSpec exercise the same `ActiveRecord::TestFixtures` code path in downstream apps. The real proof is in apps that use transactional fixtures with `before(:all)` request blocks. A targeted unit test that exercises the Rails method directly is sufficient for the gem.

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
