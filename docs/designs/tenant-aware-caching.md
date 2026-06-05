# Tenant-Aware Caching & Tenant-Context Guards

Status: implemented in PR #431 (guards + docs). Living doc — updated in place. Tracks #427.

## TLDR

Apartment isolates at the database layer and has zero `Rails.cache` integration:
cache segmentation is left to key construction, which every adopter re-derives by
hand. This design makes the tenant/cache boundary first-class without owning the
cache store. It ships a unified **tenant-context guard family** on
`Apartment::Tenant` — predicates `in_tenant?` / `in_default_tenant?`, raising
guards `require_tenant!` / `require_default_tenant!`, a `with_default_tenant { }`
block, and a `cache_namespace` helper — and documents the **routed-vs-pinned cache
model** with a two-store architecture. The guards catch the leak class where
non-request code (Sidekiq jobs, rake tasks, ActionCable callbacks) forgets to
switch and `Tenant.current` silently resolves to the default tenant, contaminating
another keyspace. The existing `inside_tenant?` / `assert_inside_tenant!` (#394) are
**renamed** to `tenant_switched?` / `assert_tenant_switched!` to dissolve a naming
collision (see [The two axes](#the-two-axes)).

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
seams: the guard family (code) and a documented cache architecture (docs). It
explicitly does NOT ship a cache adapter, a cache backend, or auto-renamespacing on
`switch`.

### The two axes

Every tenant-context question sits on one of two axes. Conflating them is what made
the original `inside_tenant?` / `in_tenant?` pair unreadable; the family below gives
each axis a distinct verb.

1. **Explicitness** — *did someone explicitly switch?* Reads raw `Current.tenant`,
   ignoring the default fallback. Audience: test discipline ("this code did not ride
   the ambient default"). Verb: **`switched`**.
2. **Identity** — *which tenant is effectively active — a real one or the default?*
   Reads effective `Tenant.current`. Audience: runtime routed/pinned decisions
   (cache, jobs, storage). Verbs: **`in_`** (predicate) / **`require_`** (guard).

The axes cannot collapse: a pinned-behavior test legitimately runs in the default
tenant, so it must satisfy the explicitness check while *failing* "am I in a real
tenant."

| Question (axis) | Predicate | Raising guard | Reads |
|---|---|---|---|
| Did a switch establish a tenant? (explicitness) | `tenant_switched?` | `assert_tenant_switched!` | `Current.tenant` present |
| Effectively in a **real** tenant? (identity) | `in_tenant?` | `require_tenant!` | `current` is non-default |
| Effectively in the **default**? (identity) | `in_default_tenant?` | `require_default_tenant!` | `current == default_tenant` |

Two mnemonics carry the surface: **`switched`** = "did a switch happen" (explicit
action); **`in_`** = "where am I now" (effective state). On the identity axis the
shapes are regular — `in_X?` asks, `require_X!` demands.

**Proof the names disambiguate.** Three states, every method:

| State | `tenant_switched?` | `in_tenant?` | `in_default_tenant?` |
|---|---|---|---|
| A. forgot to switch (inertia → default) | **false** | false | true |
| B. explicit `switch!(default)` / `reset` | **true** | false | true |
| C. `switch('acme')` | true | **true** | false |

The A-vs-B divergence is exactly where `tenant_switched?` and `in_default_tenant?`
part ways — and now the names say why (one asks "did a switch happen," the other
"where am I"). That pair was unreadable as `inside_tenant?` vs `in_default_tenant?`.

**Rename, no aliases.** `inside_tenant?` / `assert_inside_tenant!` (#394) are renamed
to `tenant_switched?` / `assert_tenant_switched!` outright. This is a breaking
change, taken cleanly because the gem is pre-1.0 alpha; no deprecated aliases are
kept. `docs/testing.md` and `docs/upgrading-to-v4.md` are updated in the same PR.

### Guards and predicates

Both raising guards read **effective** `Tenant.current` and compare with `to_s`
normalization (matching the existing `guard_default_tenant_switch!`), so
`switch!(:public)` and `default_tenant "public"` agree. They live on
`Apartment::Tenant` alongside `switch` / `current`.

```ruby
# Routed: raise TenantRequired unless current is a real, NON-default tenant.
# Catches BOTH nil-inertia (forgot to switch) AND an explicit reset to default —
# routed data never belongs in the default keyspace, however you got there.
Apartment::Tenant.require_tenant!         # => "acme" on success, else raises

# Pinned: raise unless current IS the default tenant.
# Passes on default-by-inertia AND explicit default — both yield the correct
# global keyspace for pinned writes. Raises DefaultTenantNotConfigured if no
# default_tenant is configured (see below).
Apartment::Tenant.require_default_tenant! # => default name on success, else raises

# Non-raising predicates for conditional branches:
Apartment::Tenant.in_tenant?              # current is a real, non-default tenant
Apartment::Tenant.in_default_tenant?      # current is the default tenant
```

`require_tenant!` returns the normalized tenant name on success; that return is a
documented convenience, but the cache recipe uses the purpose-named `cache_namespace`
(below) rather than relying on a bang method to yield a string.

#### `cache_namespace`

A thin, value-returning wrapper so the namespace proc reads honestly instead of
teaching "a bang returns a String":

```ruby
# Asserts a real, non-default tenant (via require_tenant!) and returns its
# normalized name. Raises TenantRequired outside a tenant context.
Apartment::Tenant.cache_namespace         # => "acme"
```

There is no `pinned_cache_namespace` counterpart, and none is needed: a pinned
namespace must be **tenant-independent** — it must not vary with
`Apartment::Tenant.current`. That is broader than "a literal constant": a config/env
value, or a per-deploy prefix like `"#{BUILD_VERSION}/global"`, is still pinned (though a
deploy prefix cold-starts the whole pinned keyspace on each deploy). Prefer an explicit
global prefix (`'pinned'`, `"#{BUILD_VERSION}/global"`) over reusing `default_tenant` as
the namespace: the latter is tenant-independent but ties the global cache layout to the
default schema's name and overlaps confusingly with default-context routed keys. To
produce pinned *data* while inside a real tenant, wrap the cache **write/read** in
`with_default_tenant` (see below) — never the namespace, which ActiveSupport re-evaluates
on every cache op.

#### `with_default_tenant`

Block primitive to **establish** global/pinned context (enter default + guaranteed
restore via `ensure`):

```ruby
Apartment::Tenant.with_default_tenant do
  PINNED_CACHE.write('feature_flags', flags)   # runs in the default/pinned context
end
```

State semantics: requires a block (raises `ArgumentError` otherwise); raises
`DefaultTenantNotConfigured` when no `default_tenant` is configured — mirroring
`require_default_tenant!`, since entering a `nil` keyspace for pinned work is the
same silent leak (both checks raise *before* touching `Current`, so a failed call
preserves the prior context); otherwise saves the prior `Current.tenant` and
restores it (including `nil`) in `ensure`, on both normal exit and raise. Nesting
restores `Current.tenant` to the enclosing value at each level; `Current.previous_tenant`
is reset to `nil` on exit (single-level, non-stacking — the same contract as the
existing `switch` primitives, not a deeper stack). As an optimization, a call made
while `Current.tenant` already equals the default is a no-op: it `yield`s in place
without re-assigning `Current.tenant` and leaves `previous_tenant` untouched (it
compares the raw `Current.tenant` slot, `to_s`-normalized like the sibling guards,
so ambient `nil` still enters the default normally).
It must NOT be a plain `switch(config.default_tenant) { }`:
under strict mode (`default_tenant_switch_allowed = false`),
`guard_default_tenant_switch!` raises on the block form into default by design —
`reset` / `switch!` are the sanctioned paths back. Entering default for pinned work
is legitimate, so `with_default_tenant` enters via the guard-exempt path (as `reset`
does) and restores in `ensure`.

#### Why two single-purpose guards, not one overloaded one

`require_tenant!` and `require_default_tenant!` encode opposite intentions that
share no happy path: "must be tenant-scoped" vs "must be global." Splitting them
keeps each call site legible and greppable, and lets both use one consistent
predicate (effective `current`) instead of one method that flips meaning based on
its argument. There is intentionally **no** `require_tenant!('acme')` named form:
overloading arity to mean "exactly this tenant" gives one method two contracts.
Code that must run in a specific tenant should `switch('acme') { … }` (which
guarantees it) or assert `Tenant.current == 'acme'` inline.

#### Exceptions

```
Apartment::ApartmentError
├── Apartment::TenantRequired               # require_tenant! failed (on default or nil-inertia)
├── Apartment::DefaultTenantRequired        # require_default_tenant! failed (on a non-default tenant)
└── Apartment::DefaultTenantNotConfigured   # require_default_tenant! with no default_tenant set
```

Distinct classes let adopters alert on each leak direction separately. Messages
state expected-vs-actual and whether the failure was implicit-default or
wrong-tenant.

**`require_default_tenant!` with no configured default raises.** When
`config.default_tenant` is nil (non-`:schema` strategies that never set one), a
naïve `current == default` check passes by `nil == nil` — but that yields an empty,
ambiguous global namespace, which is a leak dressed as a no-op. The guard instead
raises `DefaultTenantNotConfigured`: a pinned keyspace requires an explicitly named
anchor. The non-raising predicate `in_default_tenant?` is likewise **false** when no
default is configured — it does not claim you are "in" a default that does not
exist (avoiding the same `nil == nil` trap the guard rejects).

#### Why call-site asserts, not a global default-on mode

`acts_as_tenant` ships `config.require_tenant = true`, a global mode that raises on
any query issued without a tenant, because it isolates at the **query/row** layer —
every query is a natural interception point. Apartment isolates at the
**connection** layer; there is no cheap universal "you are about to touch tenant
data" hook. More decisively: the leaks this design targets (cache, Sidekiq,
ActionCable) live *outside* ActiveRecord, so a query-layer interceptor would
protect none of them. Explicit call-site assertions are the only mechanism that
guards these orthogonal boundaries, and they force the author to classify each
operation as routed or pinned. A future opt-in dev-mode *log* (warn when `current`
is read while `Current.tenant` is nil) is a possible observability add-on,
deliberately out of scope here.

### Cache architecture (documentation deliverable)

**The headline is two stores, one per data class** — not a single `config.cache_store`
line. A single `namespace: -> { current }` store forces a false choice: namespace
everything (and fragment pinned keys across N keyspaces) or namespace nothing (and
collide routed keys across tenants).

```ruby
# Routed store — fail-closed: raises TenantRequired if touched outside a real
# tenant, instead of silently writing to the default keyspace.
TENANT_CACHE = ActiveSupport::Cache::RedisCacheStore.new(
  namespace: -> { Apartment::Tenant.cache_namespace }
)

# Pinned store — tenant-independent namespace (a constant or per-deploy prefix);
# never resolves Apartment::Tenant.current. Global keys only.
PINNED_CACHE = ActiveSupport::Cache::RedisCacheStore.new(namespace: 'pinned')
```

The fail-closed routed store demonstrates the *safe* path. Documenting the older
`namespace: -> { Apartment::Tenant.current }` would itself teach the unsafe one: it
yields the default keyspace on nil-inertia.

#### Which store is `Rails.cache`?

This is the adopter's risk call, and the doc presents it as one. The default
`Rails.cache` is touched by Rails internals, third-party gems (Flipper, Rack::Attack,
Sidekiq::Web), initializers, the console, and health checks — most of that runs
outside any tenant.

- **`Rails.cache` = pinned/global, routed work uses `TENANT_CACHE` (recommended for
  most apps).** Ecosystem-safe: ambient and third-party cache calls land in the
  global keyspace and never raise. Risk: forgetting to reach for `TENANT_CACHE` on
  routed data silently collides that data across tenants in the global store.
- **`Rails.cache` = the fail-closed routed store (for security-strict apps that have
  audited every cache call).** Forgetting fail-closes *loudly* with `TenantRequired`
  rather than colliding silently. Cost: every tenant-less cache op — boot,
  initializers, console, gem internals — raises until wrapped or rerouted.

The first trades a quiet risk for compatibility; the second trades compatibility for
a loud one. Default the docs to the first; document the second as the strict opt-in.

## Edge cases / footguns (for the doc's footgun section)

- **Silent pinned-read miss.** Inside tenant `acme`, reading a global key from a
  tenant-namespaced store resolves to `acme:key` and misses permanently. Read pinned
  keys from `PINNED_CACHE`. (Per-call `namespace: nil` exists but is store-dependent
  and undercuts the fail-closed story — prefer the explicit store.)
- **Pinned store fixes shape, not provenance.** A tenant-independent `PINNED_CACHE` stops
  *namespace fragmentation*, but does not stop tenant-derived data from being written
  globally while inside `acme`. Wrap producers of pinned values in
  `with_default_tenant` / assert `require_default_tenant!`.
- **Per-request `LocalCache` with a memoized namespace.** The in-request memory layer
  keys by the *resolved* namespace, so a mid-request switch normally yields different
  keys (no stale serve). The narrow risk is code that snapshots the namespace once
  instead of recomputing it — keep the namespace a live proc.
- **Fibers / `Thread.new`.** With `isolation_level = :fiber` (the railtie enforces it),
  `Current` is fiber-local and does not propagate to raw `Thread.new`; inside one, the
  routed store raises (good) or a `current`-based key mis-namespaces (bad). Re-establish
  context in the spawned execution. Under Rails' default `:thread` isolation, fibers on
  one thread share context — another reason v4 mandates `:fiber`.
- **Key normalization.** Tenant names with `:`, whitespace, or Unicode become part of
  Redis keys. `cache_namespace` returns `to_s`; document escaping expectations and
  keep tenant names within `TenantNameValidator`'s rules.
- **`clear` is store-specific.** `RedisCacheStore#clear` with a `namespace:` deletes
  only that store's namespace; un-namespaced it issues `FLUSHDB` (whole db).
  `MemCacheStore#clear` always flushes the entire server. Document per store, not as
  one blanket "wipes everything."
- **Shared-across-a-subset (org-level) keys** are neither routed nor pinned. Don't
  force-fit: use an explicit, deliberate namespace key (e.g. `"org:#{org_id}"`), not
  `Tenant.current`.
- **Job retries** must re-establish tenant context per `perform`; switch inside the
  job, then `require_tenant!` (or write through `TENANT_CACHE`, which fail-closes).

## Testing

- Unit specs on every guard/predicate across the state matrix: nil-inertia, explicit
  `switch!(default)`, explicit non-default, inside `with_default_tenant`, and
  `default_tenant` nil. Assert the proof table above, the normalized return of
  `cache_namespace`, and the specific exception class on each failure (including
  `DefaultTenantNotConfigured`).
- `with_default_tenant` restores prior context (including `nil`) on both normal exit
  and raise, and nests.
- The rename: specs reference `tenant_switched?` / `assert_tenant_switched!`; a guard
  spec confirms `inside_tenant?` / `assert_inside_tenant!` are gone (no aliases).
- A doc-example smoke test: `TENANT_CACHE` raises `TenantRequired` outside a switch
  and namespaces correctly inside one.
- No new database dependency: guards are pure context reads, unit-testable without a
  real backend.

## Out of scope

- Owning or managing a cache store; shipping a cache backend or adapter.
- Auto-namespacing the cache on `switch`.
- Cross-process tenant-validity propagation — that is #414's transport seam
  (related, different layer).
- A global default-on guard mode and runtime path-exemption lambdas.

## Alternatives considered

- **Guards return the name; no `cache_namespace`.** Rejected: a `foo!` method whose
  return value you depend on for a String is non-idiomatic (bangs assert; they return
  `true`/`self`). `cache_namespace` carries the value role honestly; `require_tenant!`
  stays an assertion (its name return is a documented bonus).
- **Deprecated aliases for `inside_tenant?` / `assert_inside_tenant!`.** Rejected:
  pre-1.0 alpha; a clean rename beats carrying two names for the same axis.
- **`require_default_tenant!` passes when `default_tenant` is nil.** Rejected: a
  `nil == nil` pass produces an empty global namespace — a silent leak. It raises
  `DefaultTenantNotConfigured` instead.
- **Single fail-closed `config.cache_store` as the headline recipe.** Rejected as the
  *headline*: it weaponizes the default `Rails.cache`, raising on boot/console/gem
  cache calls. Demoted to the strict opt-in; the two-store split is the headline.
- **One overloaded `require_tenant!(expected = :any)`** with `:default`/name
  sentinels. Rejected: one method, two contracts (effective vs exact). The split is
  more teachable.
- **`without_tenant { }`** mirroring `acts_as_tenant`. Rejected: row-level vocabulary
  that misleads in a connection-isolation gem — there is always an effective default
  tenant. `with_default_tenant` (enter + restore) is the honest framing.
- **Block forms on the guards** (`require_tenant! { … }`). Rejected: redundant with
  `switch(tenant) { }`, which already owns context transition.
- **Global default-on query interceptor.** Rejected: wrong layer, and zero coverage
  for the non-AR leaks this design exists to catch.
