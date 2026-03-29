# Phase 2.3 Design: Connection Handling & Pool Wiring

> **Parent spec**: [`apartment-v4.md`](apartment-v4.md)
> **Phase plan**: [`plans/apartment-v4/phase-2-adapters.md`](../plans/apartment-v4/phase-2-adapters.md) — Tasks 2, 9
> **Research**: [`research/connection-handling-internals.md`](../research/connection-handling-internals.md)
> **Depends on**: Phase 2.2 (concrete adapters), Phase 1 (Config, Current, PoolManager, PoolReaper)

## Overview

Phase 2.3 implements the connection between `Apartment::Current.tenant` and ActiveRecord's connection pool resolution. When a tenant is set, AR queries must transparently use a connection pool configured for that tenant — without any `SET search_path` or `USE database` commands at switch time.

This is the architecturally sensitive piece: a single module prepended on `ActiveRecord::Base` that intercepts `connection_pool` lookups.

## Goals

1. `Apartment::Tenant.switch("acme") { User.count }` resolves a tenant-specific connection pool
2. Pool-per-tenant with immutable config — connections cannot leak tenant data
3. Works across Rails 7.2, 8.0, and 8.1 without version gates
4. Lazy pool creation on first access, cached for subsequent lookups
5. Clean eviction: pools deregistered from both `Apartment::PoolManager` and AR's `ConnectionHandler`
6. Configurable shard key prefix to avoid collisions with user-defined shards

## Non-Goals

- Replacing v3 elevators or middleware (Phase 3)
- Excluded model handling (Phase 2.4)
- Integration tests with real databases (Phase 2.4+)
- `connected_to` / `connected_to_many` interop (future — document limitations)

## Design

### 1. `Apartment::Patches::ConnectionHandling`

A module prepended on `ActiveRecord::Base` (class-level). Overrides one method: `connection_pool`.

**Pool key format**: We use `tenant.to_s` as the `PoolManager` key (e.g., `"acme"`). The parent spec's pseudocode uses `"#{connection_specification_name}[#{tenant}]"` — we deliberately simplify this because `PoolManager` is apartment-internal (not shared with AR's pool namespace), so the prefix adds no value. `AbstractAdapter#drop` already uses `tenant.to_s` as the pool key.

```ruby
module Apartment
  module Patches
    module ConnectionHandling
      def connection_pool
        tenant = Apartment::Current.tenant
        default = Apartment.config&.default_tenant

        return super if tenant.nil? || tenant == default
        return super unless Apartment.pool_manager

        pool_key = tenant.to_s

        Apartment.pool_manager.fetch_or_create(pool_key) do
          config = Apartment.adapter.resolve_connection_config(tenant)
          shard_key = :"#{Apartment.config.shard_key_prefix}_#{tenant}"

          db_config = ActiveRecord::DatabaseConfigurations::HashConfig.new(
            Apartment.config.rails_env_name,
            "apartment_#{tenant}",
            config
          )

          # owner_name receives the class (not a string) so AR wraps it
          # consistently with how it stores the default pool. This matters
          # because remove_connection_pool uses the string form of the
          # connection_name ("ActiveRecord::Base") which AR derives from
          # the class's name. Both establish_connection and
          # remove_connection_pool resolve to the same pool manager key
          # across Rails 7.2/8.0/8.1 — verified in research doc.
          ActiveRecord::Base.connection_handler.establish_connection(
            db_config,
            owner_name: ActiveRecord::Base,
            role: ActiveRecord::Base.current_role,
            shard: shard_key
          )
        end
      end
    end
  end
end
```

**Activation**: `ActiveRecord::Base.singleton_class.prepend(Apartment::Patches::ConnectionHandling)` — called during Railtie initialization or explicit `Apartment.activate!`.

**Why `connection_pool` and not `connection` / `lease_connection`**: `connection_pool` is the single chokepoint. Both `connection` and `lease_connection` delegate to it. Overriding here means all AR access patterns (`.connection`, `.with_connection`, `.lease_connection`, query execution) route through our patch.

**Why `prepend` and not `alias_method`**: `prepend` is the modern Ruby pattern. `super` calls the original method cleanly. No naming collisions, no `alias_method_chain` fragility.

**Adapter lazy-loading safety**: The `Apartment.adapter` call inside `fetch_or_create` triggers `build_adapter` if the adapter hasn't been built yet. `build_adapter` calls `ActiveRecord::Base.connection_db_config` (reads config metadata, does not establish a connection), so it does not recurse through `connection_pool`. This is safe.

### 2. Pool Resolution Flow

```
User code: User.first
  → ActiveRecord::Base.connection_pool          # our override
  → Apartment::Current.tenant == "acme"?
  → yes → pool_manager.fetch_or_create("acme")
    → cache hit?
      → yes → return cached pool (sub-millisecond)
      → no  → adapter.resolve_connection_config("acme")
            → HashConfig.new(env, "apartment_acme", config)
            → handler.establish_connection(db_config, shard: :apartment_acme)
            → AR creates pool lazily (no DB connection yet)
            → pool stored in PoolManager + AR's ConnectionHandler
            → return pool
  → pool.lease_connection → execute query
```

### 3. Data Isolation Guarantee

Each tenant pool has **immutable, tenant-specific config** baked in at creation:

| Strategy | Config key | Example |
|----------|-----------|---------|
| PostgreSQL schema | `schema_search_path` | `"acme,ext,public"` |
| PostgreSQL database | `database` | `"acme_production"` |
| MySQL database | `database` | `"acme_production"` |
| SQLite file | `database` | `"storage/acme.sqlite3"` |

A connection checked out from tenant A's pool is **physically unable** to access tenant B's data. No runtime SQL commands change the tenant context — the pool *is* the tenant boundary.

For PostgreSQL schema strategy: Rails' `PostgreSQLAdapter#configure_connection` issues a one-time `SET search_path` when establishing each new connection within the pool. This happens once per connection (not per request), and the search_path matches the pool's config. See the parent spec for PgBouncer compatibility notes.

### 4. Shard Key Namespacing

Tenant shard keys are prefixed to avoid collisions with user-defined shards:

```ruby
shard_key = :"#{config.shard_key_prefix}_#{tenant}"
# With default prefix: :apartment_acme
# With custom prefix:  :myapp_acme
```

**Config addition**: `config.shard_key_prefix` — string, default `"apartment"`, validated as `/\A[a-z_][a-z0-9_]*\z/`.

User apps that use `connects_to shards: { shard_one: ... }` will not collide with `:apartment_acme`.

### 5. Config Changes

#### New attributes on `Apartment::Config`

| Attribute | Type | Default | Purpose |
|-----------|------|---------|---------|
| `shard_key_prefix` | String | `"apartment"` | Prefix for shard keys in AR's ConnectionHandler |

#### New method on `Apartment::Config`

`rails_env_name` — returns `Rails.env` when available, falls back to `ENV["RAILS_ENV"]`, `ENV["RACK_ENV"]`, or `"default_env"`. Mirrors ActiveRecord's own `ConnectionHandling::DEFAULT_ENV` lambda. Used as the `env_name` parameter for `HashConfig.new`.

#### Validation

`shard_key_prefix` validated in `validate!`:
- Must be a non-empty string
- Must match `/\A[a-z_][a-z0-9_]*\z/` (safe for `to_sym`)
- Raises `ConfigurationError` on invalid values

### 6. Pool Eviction — AR Handler Cleanup

When `PoolReaper` evicts a tenant, it must clean up both sides. Both `evict_idle` and `evict_lru` methods must be updated to include AR handler cleanup (the current code only removes from `PoolManager`).

Updated eviction flow per tenant:

```ruby
# 1. Remove from our tracking (prevents new lookups)
pool = @pool_manager.remove(tenant_key)

# 2. Deregister from AR's handler (disconnects connections)
#    remove_connection_pool accepts the connection_name as a string.
#    AR's ConnectionHandler resolves "ActiveRecord::Base" → same pool
#    manager used by establish_connection(owner_name: ActiveRecord::Base).
shard_key = :"#{@shard_key_prefix}_#{tenant_key}"
begin
  ActiveRecord::Base.connection_handler.remove_connection_pool(
    "ActiveRecord::Base",
    role: ActiveRecord::Base.current_role,
    shard: shard_key
  )
rescue StandardError => e
  warn "[Apartment::PoolReaper] Failed to deregister pool for #{tenant_key}: #{e.class}: #{e.message}"
end
```

**Order matters**: Remove from `PoolManager` first so concurrent `connection_pool` calls don't find a stale entry. Then deregister from AR's handler, which calls `disconnect!` on the pool.

**`PoolManager#clear` also needs AR cleanup**: When `teardown_old_state` calls `@pool_manager.clear`, it must also deregister each pool from AR's handler. Otherwise stale shard registrations persist in AR's `ConnectionHandler` after reconfigure. The updated `clear` method iterates tracked tenant keys and calls `remove_connection_pool` for each before clearing the maps.

The `on_evict` callback (existing) fires after removal for instrumentation/logging.

### 7. PoolReaper: Class Singleton → Instance

**Current state**: `PoolReaper` uses class-level `@mutex`, `@timer`, and class methods. Works but prevents test isolation and couples global state.

**New design**: `PoolReaper` becomes an instance held by `Apartment`:

```ruby
module Apartment
  class << self
    attr_reader :pool_reaper

    def configure
      # ... validate, freeze ...
      teardown_old_state
      @pool_manager = PoolManager.new
      @pool_reaper = PoolReaper.new(
        pool_manager: @pool_manager,
        interval: new_config.pool_idle_timeout,
        idle_timeout: new_config.pool_idle_timeout,
        max_total: new_config.max_total_connections,
        default_tenant: new_config.default_tenant,
        shard_key_prefix: new_config.shard_key_prefix
      )
      @config = new_config
      @pool_reaper.start
    end

    def clear_config
      teardown_old_state
      @config = nil
      @pool_manager = nil
      @pool_reaper = nil
    end
  end
end
```

**Reap interval**: Uses `pool_idle_timeout` as the timer interval (matching the parent spec and existing behavior). No separate `pool_reap_interval` attribute — the reaper checks at the same frequency as the idle timeout. This means a pool could live up to 2x the idle timeout before eviction (idle for `timeout` seconds, then up to `timeout` more seconds until the next check). This is acceptable for the intended use case. A separate reap interval can be added later if needed.

**`clear_config` update**: Must call `teardown_old_state` (which stops the reaper instance) instead of `PoolReaper.stop` (the old class-method call).

Instance API:
- `initialize(pool_manager:, interval:, idle_timeout:, max_total:, default_tenant:, shard_key_prefix:)` — validates params
- `start` — creates and executes `Concurrent::TimerTask`
- `stop` — shuts down timer, waits for termination
- `running?` — timer state check
- `reap` (private) — calls `evict_idle`, `evict_lru`

The reaper instance holds `shard_key_prefix` so eviction can compute shard keys for `remove_connection_pool`.

### 8. `configure` Teardown Protection

Wrap teardown in begin/rescue so a `PoolReaper.stop` failure doesn't leave half-torn-down state:

```ruby
def teardown_old_state
  begin
    @pool_reaper&.stop
  rescue StandardError => e
    warn "[Apartment] PoolReaper.stop failed during reconfigure: #{e.class}: #{e.message}"
  end
  @pool_manager&.clear
  @adapter = nil
end
```

### 9. Activation API

The patch must be activated explicitly (not on `require`). Two paths:

1. **With Rails (Railtie)**: Activated in `after_initialize` — AR is guaranteed loaded.
2. **Without Rails**: `Apartment.activate!` — user calls after `Apartment.configure`.

```ruby
module Apartment
  def self.activate!
    ActiveRecord::Base.singleton_class.prepend(Patches::ConnectionHandling)
  end
end
```

Idempotent — `prepend` on an already-prepended module is a no-op.

## File Map

### New files

| File | Responsibility |
|------|---------------|
| `lib/apartment/patches/connection_handling.rb` | `connection_pool` override |
| `spec/unit/patches/connection_handling_spec.rb` | Unit tests for pool resolution |

### Modified files

| File | Changes |
|------|---------|
| `lib/apartment/config.rb` | Add `shard_key_prefix`, `rails_env_name`, validation |
| `lib/apartment/pool_reaper.rb` | Convert from class singleton to instance, add AR handler cleanup |
| `lib/apartment.rb` | Add `pool_reaper` accessor, `activate!` method, extract `teardown_old_state`, update both `configure` and `clear_config` to use instance reaper (not class singleton) |
| `spec/unit/pool_reaper_spec.rb` | Update for instance API |
| `spec/unit/config_spec.rb` | Add `shard_key_prefix` validation tests |
| `spec/unit/apartment_spec.rb` | Add `activate!` tests, teardown protection tests |

### Zeitwerk

`lib/apartment/patches/` is currently in the Zeitwerk ignore list. The `connection_handling.rb` file will be loaded via `require_relative` (explicit, not autoloaded) since it must be activated at a specific point in the boot sequence.

## Testing Strategy

Unit tests use SQLite3 in-memory databases (no external services). Test with real AR loaded (not stubs) — the patch must exercise actual `ConnectionHandler` and `PoolConfig` behavior.

### `spec/unit/patches/connection_handling_spec.rb`

- Default tenant → returns `super` (normal AR pool)
- `nil` tenant → returns `super`
- Active tenant → returns tenant-specific pool (different from default)
- Same tenant twice → returns same cached pool
- Different tenants → return different pools
- Pool is registered with AR's `ConnectionHandler`
- Pool has correct `db_config` (tenant-specific settings)
- Pool is usable (can execute a simple query)
- No `PoolManager` (unconfigured) → returns `super`
- Tenant name with hyphens (e.g., `"my-tenant"`) works correctly as shard key
- Role interaction: tenant pool under `:reading` role differs from `:writing`

### `spec/unit/pool_reaper_spec.rb` (updated)

- Instance creation with valid params
- Instance `start`/`stop` lifecycle
- Idle eviction calls `disconnect!` and deregisters from AR handler
- LRU eviction calls `disconnect!` and deregisters from AR handler
- Default tenant is never evicted
- Multiple start/stop cycles work cleanly

### `spec/unit/config_spec.rb` (additions)

- `shard_key_prefix` defaults to `"apartment"`
- Valid prefix passes validation
- Invalid prefix (empty, special chars, starts with number) raises `ConfigurationError`
- `rails_env_name` returns correct value with/without Rails

### `spec/unit/apartment_spec.rb` (additions)

- `configure` teardown rescues `PoolReaper.stop` failure
- `activate!` prepends `ConnectionHandling` on `ActiveRecord::Base`
- `clear_config` stops reaper instance

## Interactions and Edge Cases

### User calls `connected_to(shard: :foo)`

Our patch reads `Current.tenant`, not `current_shard`. If the user switches shards via `connected_to(shard:)`, our override still reads `Current.tenant` first. If tenant is set, we return our pool (ignoring the user's shard switch). If tenant is nil/default, `super` runs and respects the user's shard.

**Implication**: Inside an `Apartment::Tenant.switch` block, user-level `connected_to(shard:)` is overridden by our tenant pool. This is the correct behavior — tenant isolation takes precedence.

### User calls `connected_to(role: :reading)`

If the user is inside `connected_to(role: :reading)` and also inside `Tenant.switch("acme")`, our override passes `role: ActiveRecord::Base.current_role` (which will be `:reading`) to `establish_connection`. This means tenant pools are created per `(tenant, role)` pair, not just per tenant. This is correct and intentional — a tenant's reading replica should be a different pool from its writing primary.

### `prohibit_shard_swapping`

Does not affect us. We don't push to `connected_to_stack`; we read `Current.tenant` directly.

### Forking servers (Puma, Unicorn)

After fork, `Concurrent::Map` in `PoolManager` starts empty (copy-on-write semantics). AR's `clear_all_connections!` on fork is respected. The reaper's `Concurrent::TimerTask` does NOT survive fork — must be restarted in the worker process (Railtie `on_worker_boot` hook, Phase 3).

### `ActiveRecord::Base` subclasses with custom `connection_specification_name`

Our patch is on `ActiveRecord::Base` singleton class. Subclasses that set their own `connection_specification_name` (e.g., via `establish_connection` or `connects_to`) resolve their pool via the parent's `connection_pool` method — which calls our override. If the subclass has its own pool (from `connects_to`), AR's `retrieve_connection_pool` finds it before reaching our code (because `super` is called only for default/nil tenant). Excluded models will be handled in Phase 2.4.

## Risks

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| AR internal API changes in Rails 8.2+ | Medium | High | We use only public APIs (`establish_connection`, `remove_connection_pool`, `HashConfig.new`). CI matrix catches regressions. |
| `establish_connection` idempotent check fails for schema strategy (same DB, different search_path) | Low | Medium | Each tenant has a different `HashConfig` (different `schema_search_path`), so `db_config ==` comparison should differentiate. Verify in tests. |
| Thread contention on `PoolManager.fetch_or_create` | Low | Low | `Concurrent::Map.compute_if_absent` is lock-free for the common (cache hit) path. |
| Memory growth with many tenants | Medium | Medium | PoolReaper evicts idle/LRU pools. `max_total_connections` provides hard cap. |
