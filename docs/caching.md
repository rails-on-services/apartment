# Tenant-Aware Caching

Apartment isolates the **database**. The cache (Redis/ValKey/Memcached/Solid
Cache) is a separate shared store, correctly segmented only if your keys carry
the right tenant. This guide makes that boundary explicit. See
`docs/designs/tenant-aware-caching.md` for the rationale.

## Routed vs pinned

Cache data splits into the two classes Apartment already models for ActiveRecord:

| Class | Examples | Namespacing |
|---|---|---|
| **Routed** (per-tenant) | fragments, query caches, per-tenant computed values | key MUST include the tenant |
| **Pinned** (global) | feature flags, app-wide config, schema versions | key MUST NOT be tenant-namespaced |

Pinned data is global truth; namespacing it per-tenant fragments one registry
across N tenant keyspaces.

## The leak this prevents

`Apartment::Tenant.current` returns the **default tenant** when nobody switched.
A Sidekiq job, rake task, or ActionCable callback that forgot to switch writes
routed cache data into the default keyspace — cross-tenant contamination. Guard
against it explicitly.

## Guards

```ruby
Apartment::Tenant.require_tenant!          # raise unless in a real, non-default tenant; returns its name
Apartment::Tenant.require_default_tenant!  # raise unless in the default tenant; returns its name
Apartment::Tenant.in_tenant?               # predicate (non-raising)
Apartment::Tenant.in_default_tenant?       # predicate (non-raising)
Apartment::Tenant.with_default_tenant { }  # run a block in the default/pinned context
Apartment::Tenant.cache_namespace          # require_tenant! + return the name; for namespace procs
```

> `tenant_switched?` / `assert_tenant_switched!` are the **explicitness** axis —
> test discipline only. They pass in the default tenant, so never use them to
> guard routed cache or job work. Use `require_tenant!` (identity axis) for that.

The predicates resolve across the three context states as follows. Note that
`in_default_tenant?` passes on default-by-inertia *and* an explicit default — it
asks "where am I effectively?", not "did I deliberately enter default?". For the
latter (test discipline) use `tenant_switched?`.

| Context state | `tenant_switched?` | `in_tenant?` | `in_default_tenant?` |
|---|---|---|---|
| Forgot to switch (default by inertia) | false | false | true |
| Explicit `switch!(default)` / `reset` | true | false | true |
| Real tenant (`switch('acme')`) | true | true | false |

(When no `default_tenant` is configured, `in_default_tenant?` is false and both
predicates can be false at once; the raising guards `require_tenant!` /
`require_default_tenant!` are exhaustive where the predicates are not.)

```ruby
class RebuildFragmentsJob
  def perform(tenant)
    Apartment::Tenant.switch(tenant) do
      Apartment::Tenant.require_tenant!     # fail loudly if the switch was wrong
      Rails.cache.write(key, value)
    end
  end
end
```

## Two-store architecture

Use one store per data class. A single `namespace: -> { current }` store cannot
host both: namespace everything and pinned keys fragment across tenants;
namespace nothing and routed keys collide.

```ruby
# Routed store — fail-closed: raises TenantRequired if touched outside a tenant.
TENANT_CACHE = ActiveSupport::Cache::RedisCacheStore.new(
  namespace: -> { Apartment::Tenant.cache_namespace }
)

# Pinned store — tenant-INDEPENDENT namespace (a constant, or a per-deploy prefix
# like "#{BUILD_VERSION}/global"); never resolves Apartment::Tenant.current. Global keys only.
PINNED_CACHE = ActiveSupport::Cache::RedisCacheStore.new(namespace: 'pinned')
```

### Which store is `Rails.cache`?

`Rails.cache` is touched by Rails internals, third-party gems (Flipper,
Rack::Attack, Sidekiq::Web), initializers, and the console — mostly outside any
tenant. Two options, your risk call:

- **`Rails.cache` = pinned/global, routed work uses `TENANT_CACHE` (recommended).**
  Ambient and third-party cache calls land in the global keyspace and never
  raise. Risk: forgetting `TENANT_CACHE` for routed data silently collides it
  across tenants.
- **`Rails.cache` = the fail-closed routed store (strict; audit first).**
  Forgetting fail-closes loudly with `TenantRequired`. Cost: every tenant-less
  cache op (boot, console, gem internals) raises until rerouted.

## Footguns

- **Silent pinned-read miss.** Inside tenant `acme`, reading a global key from a
  tenant-namespaced store resolves to `acme:key` and misses permanently. Read
  pinned keys from `PINNED_CACHE`.
- **Pinned store fixes shape, not provenance.** It stops fragmentation, not
  tenant-derived data being written globally while inside `acme`. Wrap producers
  of pinned values in `with_default_tenant` or assert `require_default_tenant!`.
- **Per-request `LocalCache` with a memoized namespace.** ActiveSupport's
  in-request memory layer keys by the *resolved* namespace, so a mid-request
  switch normally yields different keys (no stale serve). The narrow risk is
  custom code that captures the namespace once instead of recomputing it — keep
  the namespace a live proc (`-> { cache_namespace }`), never a value snapshotted
  at store construction.
- **Fibers / `Thread.new`.** With `isolation_level = :fiber` (the v4 railtie
  enforces it), `Current` is fiber-local and does not propagate into a raw
  `Thread.new` — re-establish context in the spawned execution. Under Rails' default
  `:thread` isolation, fibers on one thread would *share* context, which is why v4
  mandates `:fiber`.
- **`clear` is store-specific — know yours before calling it.**
  `RedisCacheStore#clear` with a configured `namespace:` deletes only that store's
  namespace (`PINNED_CACHE.clear` wipes `pinned:*`, the routed store wipes the
  *current* tenant's namespace); with NO namespace it issues `FLUSHDB` and wipes
  the entire Redis db — every tenant and every other app sharing it.
  `MemCacheStore#clear` always flushes the whole server (no namespace scoping).
- **Key normalization.** Tenant names become part of the Redis key.
  `cache_namespace` returns `to_s` with no escaping, so names with `:`, whitespace,
  or Unicode produce surprising keys — keep tenant names within
  `TenantNameValidator`'s rules.
- **A real tenant literally named the default** (e.g. a customer slug `"public"`):
  the identity axis treats it as the default, so `in_tenant?` is false and routed
  cache is rejected for it — even though connection routing still uses that name.
  Avoid reusing the `default_tenant` name as a real tenant.
- **Org-level keys** (shared across a subset of tenants) are neither routed nor
  pinned — use an explicit `"org:#{org_id}"` namespace, not `Tenant.current`.
- **Job retries** must re-establish tenant context per `perform`.

## Schema-cache recovery

In v4, each tenant has its own connection pool and therefore its own schema
cache, so one tenant's DDL cannot corrupt another tenant's cache. After a
migration, the only staleness is the ordinary Rails "warm worker holds the old
schema until reload" — cured by your deploy restart. The one apartment-specific
case is DDL on a **pinned/shared (public-schema) table**: every warm tenant pool
that cached that table now holds stale metadata.

For that case (or manual DDL in a console), clear the cache in the current
process:

```ruby
Apartment::Tenant.reload_schema_cache!          # all warm tenant pools + default pool
Apartment::Tenant.reload_schema_cache!("acme")  # only that tenant's warm pools
```

It clears each pool's schema reflection; the next query re-reflects the
database. Returns the count of pools cleared.

**Limits — read before relying on it:**

- **Current process only.** It cannot reach other workers (web/Sidekiq). After
  fleet-wide DDL, a rolling restart remains the cure; this helper is for the
  process you call it from (console, a post-migrate maintenance script).
- **Schema reflection only, not prepared statements.** On PostgreSQL,
  ActiveRecord self-heals stale prepared statements (`cached plan must not
  change result type` → retry). On MySQL there is no equivalent auto-retry, so
  restart is more load-bearing there.
- **Does not reset model column caches.** A model class that already loaded its
  columns keeps them until `YourModel.reset_column_information` or a restart.
  This helper clears the *pool* cache, not `ActiveRecord::Base` model state.
- **Not a barrier.** An in-flight request may still use metadata it already
  read. Call it during a maintenance window / low-traffic moment, the same way
  Rails clears the schema cache after `db:migrate`.
- **Default pool is cleared for the current role only.** Warm tenant pools are
  cleared across all roles, but the default (untenanted) pool is cleared only
  for the role you call from. A multi-role app with a `:reading` default replica
  should call once per role (e.g. inside `connected_to(role: :reading)`) to
  clear the replica default pool. For pinned/shared-table DDL, use the unscoped
  `reload_schema_cache!` — a tenant-scoped call clears only that tenant's pools.

Backward-compatible (additive) migrations rarely need this at all: old code does
not reference the new column, so a stale cache is inert until the next restart.
