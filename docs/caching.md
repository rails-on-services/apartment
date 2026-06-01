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
