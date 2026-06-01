# Tenant-Aware Caching & Tenant-Context Guards

Status: draft. Living doc — updated in place as the feature lands. Tracks #427.

## TLDR

Apartment isolates at the database layer and has zero `Rails.cache` integration:
cache segmentation is left to key construction, which every adopter re-derives by
hand. This design makes the tenant/cache boundary first-class without owning the
cache store. It ships two **tenant-context guard primitives** —
`Apartment::Tenant.require_tenant!` (routed work) and `require_default_tenant!`
(pinned/global work) — plus a `with_default_tenant { }` block, and documents the
**routed-vs-pinned cache model** with a fail-closed namespace recipe. The guards
catch the leak class where non-request code (Sidekiq jobs, rake tasks,
ActionCable callbacks) forgets to switch and `Tenant.current` silently resolves to
the default tenant, contaminating another keyspace.

## Problem

Any resource keyed off `Apartment::Tenant.current` is correct only inside a switch
context. On the request path the elevator guarantees that; everywhere else the
"always use `switch(tenant) { … }`" discipline does. The cache inherits the same
rule, but nothing surfaces it.

`Tenant.current` returns `Current.tenant || config.default_tenant`. In a Sidekiq
job, rake task, console session, or ActionCable callback that forgot to switch,
`Current.tenant` is `nil`, so `current` resolves to the **default tenant**. A cache
key built from `current` then silently lands in the default-tenant namespace. The
failure mode is **cross-tenant cache contamination**: reading or writing another
tenant's cached data — a confidentiality leak, strictly worse than the 500-vs-404
regression tracked in #414.

The cache is not special. It is a shared external store (Redis/ValKey) keyed by a
string; it is correctly segmented if and only if `current` is correct at the moment
the key is computed. The same leak applies to every `current`-derived resource:
ActiveStorage paths, search indices, computed-value memoization.

## The model: routed vs pinned, applied to cache

Cache data splits into exactly the two classes Apartment already models for
ActiveRecord:

| Model concept | Cache analog | Namespacing |
|---|---|---|
| **Routed** (tenant table) | fragments, query caches, per-tenant computed values | key MUST include the tenant |
| **Pinned** (global table via `pin_tenant`) | tenant-validity set (#414), feature flags, app-wide config, schema versions | key must NOT be tenant-namespaced |

Pinned cache data is *global truth*; namespacing it per-tenant fragments one global
registry across N tenant keyspaces. That is the exact footgun that makes a
`Rails.cache`-backed `TenantValidator` wrong in #414: the validity set is **pinned**.
Naming the distinction for cache unifies it with the `pin_tenant` distinction
Apartment already draws for models.

## Design

Apartment owns the **distinction and the discipline**, not the cache store. Two
seams: guard primitives (code) and a documented cache recipe (docs). It explicitly
does NOT ship a cache adapter, a cache backend, or auto-renamespacing on `switch`.

### Guard primitives

Both guards read **effective** `Tenant.current` (default fallback included) and
**return the tenant name on success**, so a guard can serve directly as a cache
namespace proc. They live on `Apartment::Tenant` alongside `switch`/`current`.

```ruby
# Routed: raise unless current is a real, NON-default tenant.
# Catches BOTH nil-inertia (forgot to switch) AND an explicit reset to default —
# routed data never belongs in the default keyspace, however you got there.
Apartment::Tenant.require_tenant!        # => "acme" (on success), else raises TenantRequired

# Pinned: raise unless current IS the default tenant.
# Passes on default-by-inertia AND explicit default — both yield the correct
# global keyspace for pinned writes.
Apartment::Tenant.require_default_tenant!  # => default name, else raises DefaultTenantRequired
```

Predicate (non-raising) forms for conditional branches:

```ruby
Apartment::Tenant.in_tenant?          # current is a real, non-default tenant
Apartment::Tenant.in_default_tenant?  # current is the default tenant
```

Block primitive to **establish** global/pinned context (enter default + guaranteed
restore via `ensure`); reads as intent at the call site:

```ruby
Apartment::Tenant.with_default_tenant do
  PINNED_CACHE.write('feature_flags', flags)   # runs in the default/pinned context
end
```

Implementation note: `with_default_tenant` must NOT be a plain
`switch(config.default_tenant) { }`. Under strict mode
(`default_tenant_switch_allowed = false`), `guard_default_tenant_switch!` raises on
the block form into default by design — `reset`/`switch!` are the sanctioned paths
back. Entering default for pinned work is legitimate, so `with_default_tenant`
saves `Current.tenant`, enters default via the guard-exempt path (as `reset`
does), and restores in `ensure` — bypassing `guard_default_tenant_switch!` exactly
as `reset` and `switch!` already do.

#### Why two single-purpose methods, not one overloaded guard

`require_tenant!` and `require_default_tenant!` encode opposite intentions that
share no happy path: "must be tenant-scoped" vs "must be global." Splitting them
keeps each call site legible and greppable, and lets both use one consistent
predicate (effective `current`) instead of one method that flips meaning based on
its argument. There is intentionally **no** `require_tenant!('acme')` named form:
overloading arity to mean "exactly this tenant" gives one method two contracts.
Code that must run in a specific tenant should `switch('acme') { … }` (which
guarantees it) or assert `Tenant.current == 'acme'` inline.

#### Relationship to `assert_inside_tenant!`

`inside_tenant?` / `assert_inside_tenant!` (shipped in #394) stay unchanged. They
read **raw `Current.tenant`** (explicit-entry semantics, ignoring the default
fallback) and answer a *test* question: "did this spec enter any tenant context at
all?" — so an explicit `switch!(default)` satisfies them. The new `require_*`
guards read **effective `Tenant.current`** and answer a *production* question:
"am I on routed data / global data?" — so `require_tenant!` rejects an explicit
default. Two audiences, two predicates; the docs name the distinction to prevent
the "I'm inside a tenant — why did `require_tenant!` raise?" confusion (answer:
you are on `default`).

#### Exceptions

```
Apartment::ApartmentError
├── Apartment::TenantRequired          # require_tenant! failed (on default or nil-inertia)
└── Apartment::DefaultTenantRequired   # require_default_tenant! failed (on a non-default tenant)
```

Distinct classes let adopters alert on each leak direction separately. Messages
state expected-vs-actual and whether the failure was implicit-default or
wrong-tenant.

#### Why call-site asserts, not a global default-on mode

`acts_as_tenant` ships `config.require_tenant = true`, a global mode that raises on
any query issued without a tenant, because it isolates at the **query/row** layer —
every query is a natural interception point. Apartment isolates at the
**connection** layer; there is no cheap universal "you are about to touch tenant
data" hook. More decisively: the leaks this design targets (cache, Sidekiq,
ActionCable) live *outside* ActiveRecord, so a query-layer interceptor would
protect none of them. Explicit call-site assertions are the only mechanism that
guards these orthogonal boundaries, and they force the author to classify each
operation as routed or pinned. A future opt-in dev-mode *log* (warn when
`current` is read while `Current.tenant` is nil) is a possible observability
add-on, deliberately out of scope here.

### Cache recipe (documentation deliverable)

The guard's return value makes the routed recipe **fail-closed**:

```ruby
# Routed store — raises (TenantRequired) if ANYTHING touches it outside a tenant
# switch, instead of silently writing to the default keyspace.
config.cache_store = :redis_cache_store,
  namespace: -> { Apartment::Tenant.require_tenant! }
```

Documenting the older `namespace: -> { Apartment::Tenant.current }` would itself
demonstrate the unsafe path: it yields the default keyspace on nil-inertia. The
guard-as-namespace closes that.

The fail-closed store cannot also hold pinned keys (it would raise on every global
access). Pinned data goes to a **separate store** with a static namespace:

```ruby
# Pinned store — STATIC namespace, never a tenant lambda. Global keys only.
PINNED_CACHE = ActiveSupport::Cache::RedisCacheStore.new(namespace: 'pinned')
```

This two-store rule is the load-bearing conclusion. A single
`namespace: -> { current }` store forces a false choice: namespace everything (and
fragment pinned keys across N keyspaces) or namespace nothing (and collide routed
keys across tenants).

## Edge cases / footguns (for the doc's footgun section)

- **Silent pinned-read miss.** Inside tenant `acme`, `Rails.cache.read('flag')` on a
  tenant-namespaced store becomes `acme:flag` and misses the global value
  permanently. Read pinned keys from `PINNED_CACHE`, or pass `namespace: nil` per
  call. This is *why* two stores, not one.
- **`Rails.cache.clear` on shared Redis** wipes every tenant's keyspace at once.
  Flag prominently; prefer per-namespace expiry.
- **Shared-across-a-subset (org-level) keys** are neither routed nor pinned. Don't
  force-fit: use an explicit, deliberate namespace key (e.g. `"org:#{org_id}"`),
  not `Tenant.current`.
- **Job retries** must re-establish tenant context per `perform`; the namespace
  lambda re-evaluates correctly only if the connection/context matches. Switch
  inside the job, then `require_tenant!`.
- **Fragment caching in shared layouts** can render in mixed context; scope each
  fragment's tenant explicitly or source shared partials from `PINNED_CACHE`.
- **`require_default_tenant!` when `default_tenant` is nil** (non-`:schema`
  strategies that never set one): `current` is nil and equals the nil default, so
  the guard passes. Documented; apps wanting a hard global anchor should configure
  a `default_tenant`.

## Testing

- Unit specs on each guard across the state matrix: nil-inertia, explicit
  `switch!(default)`, explicit non-default, `with_default_tenant` block,
  `default_tenant` nil. Assert return values (name on success) and the specific
  exception class on failure.
- `with_default_tenant` restores prior context on both normal exit and raise.
- A doc-example smoke test that the fail-closed namespace proc raises
  `TenantRequired` outside a switch and returns the name inside one.
- No new database dependency: guards are pure context reads, unit-testable without
  a real backend.

## Out of scope

- Owning or managing a cache store; shipping a cache backend or adapter.
- Auto-namespacing the cache on `switch`.
- Cross-process tenant-validity propagation — that is #414's transport seam
  (related, different layer).
- A global default-on guard mode and runtime path-exemption lambdas.

## Alternatives considered

- **One overloaded `require_tenant!(expected = :any)`** with `:default`/name
  sentinels. Rejected: one method, two contracts; the `:default` and named cases
  read with different (effective vs exact) semantics. The split is more teachable.
- **`without_tenant { }`** mirroring `acts_as_tenant`. Rejected: row-level
  vocabulary that misleads in a connection-isolation gem — there is always an
  effective default tenant. `with_default_tenant` (switch + restore) is the honest
  framing.
- **Block forms on the guards** (`require_tenant! { … }`). Rejected: redundant with
  `switch(tenant) { }`, which already owns context transition. Guards assert;
  `switch` establishes; conflating them invites nested-switch bugs.
- **Global default-on query interceptor.** Rejected: wrong layer (see above) and
  zero coverage for the non-AR leaks this design exists to catch.
- **Documenting `namespace: -> { Tenant.current }`.** Rejected: demonstrates the
  unsafe default-by-inertia path; the guard-as-namespace is fail-closed.
