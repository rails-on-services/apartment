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

# Pinned store — STATIC namespace, never a tenant lambda. Global keys only.
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
- **Per-request `LocalCache`.** ActiveSupport's in-request memory layer keys by
  the namespace at access time; don't switch tenants mid-request around cached
  reads, or a stale tenant may be served from memory.
- **Fibers / `Thread.new`.** `Current` is fiber-local and does not propagate to a
  raw thread; re-establish context in the spawned execution.
- **`Rails.cache.clear`** on shared Redis wipes every tenant's keyspace. Prefer
  per-namespace expiry.
- **Org-level keys** (shared across a subset of tenants) are neither routed nor
  pinned — use an explicit `"org:#{org_id}"` namespace, not `Tenant.current`.
- **Job retries** must re-establish tenant context per `perform`.
