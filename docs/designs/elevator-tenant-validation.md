# Elevator Tenant Validation & Not-Found Handling

Status: draft. Living doc — updated in place as the feature lands.

## TLDR

Elevators switch to whatever tenant name they resolve, with no check that the
tenant exists. An unknown or typo'd subdomain switches into a non-existent
schema, and a raw database error surfaces deep in the first query as an opaque
500. This design adds two pluggable seams to `Generic#call`: a `tenant_validator`
("is this a real tenant?") and the existing-but-dead `tenant_not_found_handler`
("what response on a miss?"). A built-in memoized validator runs **on by
default**; an unknown tenant raises `Apartment::TenantNotFound`, which the
railtie maps to `:not_found` so the app's own 404 page renders with zero config.

## Problem

`Apartment::Elevators::Generic#call` resolves a tenant name from the request and
calls `Apartment::Tenant.switch(name) { @app.call }` **unconditionally**. Nothing
verifies that `name` is a real tenant.

`Tenant.switch` only sets `Current.tenant`; the actual database work happens
later, when ActiveRecord asks for a connection pool. So an unknown tenant fails
late and opaquely: a `PG`/adapter error (often re-wrapped as a generic
`Apartment::ApartmentError`) surfaces mid-request and the app returns a 500 that
looks like a database fault, not a routing miss.

Two pieces meant to address this already exist but are inert:

- `config.tenant_not_found_handler` — a `Config` accessor (defaults to `nil`),
  **wired nowhere**.
- The v4 design docs describe the intended behavior but **contradict each other**
  on the layer: `apartment-v4.md` says the elevator calls the handler when it
  resolves a name that doesn't exist; `v4-elevators.md` calls
  `tenant_not_found_handler` "an adapter-level hook, not a middleware-level one."
  The handler's own shape — `->(tenant, request) { [status, headers, body] }`,
  taking a request and returning a Rack response — settles it: this is
  middleware-level, and `v4-elevators.md`'s contradicting line is corrected.

Apartment has never validated tenants in the elevator, in v3 or v4. Consumers
hand-roll "rescued tenant elevator" subclasses that override `call` and rescue.

## Design

### Two seams

The fix is two pluggable hooks in `Generic#call`, between *resolve* and *switch*:

| Config | Shape | Question it answers | Default |
|---|---|---|---|
| `tenant_validator` | `->(tenant_name) { true \| false }` | Is this a real tenant? | built-in validator (on) |
| `tenant_not_found_handler` | `->(tenant, request) { [status, headers, body] }` | What response on a miss? | `nil` → raise `TenantNotFound` |

The validator is **name-only** by deliberate design: resolving a tenant from
request context (header, custom domain, SSO param) is already `parse_tenant_name`'s
job. The validator answers a narrower question — given a resolved name, is it a
tenant — and keeping it name-only makes it trivially cacheable and reusable
outside a request.

### `Generic#call` flow

```
request → parse_tenant_name
            │
            ├─ nil  ──────────────→ @app.call            (no switch; default tenant — unchanged)
            │
            └─ name → tenant_valid?(name)
                         ├─ true  → Tenant.switch(name) { @app.call }
                         └─ false → handle_tenant_not_found(name, request)
```

`handle_tenant_not_found` calls `config.tenant_not_found_handler` if configured
(returning its Rack response), otherwise raises `Apartment::TenantNotFound`.

`tenant_valid?` consults `config.tenant_validator`: `false` disables validation
(every name passes — today's behavior); a callable is invoked; the default
built-in validator is used when unset.

A `TenantNotFound` raised *during tenant resolution itself* — `HostHash` raises
it from `parse_tenant_name` on an unmapped host — is caught **narrowly around the
`@processor.call`** and routed through the same `handle_tenant_not_found` path,
so every elevator's not-found case flows through one handler. The rescue does
**not** wrap `@app.call`; a `TenantNotFound` raised by the application for its
own reasons is never swallowed.

### Built-in validator

`Apartment::TenantValidator` — a process-local memoized registry. It never calls
`tenants_provider` per request; that callable is the *source* of names and may be
a database query.

- **Positive set** — a thread-safe `Set` of valid tenant names, built lazily on
  first use from `config.tenants_provider` directly. Not via
  `Apartment.tenant_names`, which honors the per-block `with_tenants` override —
  the process-global registry must reflect the configured provider, not a
  block-scoped (test) override.
- **Rebuild-on-miss — rate-limited and single-flight.** A name absent from the
  set triggers a rebuild from the source, *at most once per rebuild interval* (a
  flood of distinct unknown names cannot hammer `tenants_provider`) and
  *single-flight* (a mutex; one thread rebuilds). The **first build is
  blocking** — concurrent callers wait for it, since there is no usable current
  set to fall back on yet; a non-blocking first build would evaluate against the
  empty initial set and 404 a valid tenant. Later refreshes are non-blocking: a
  caller that loses the lock uses the still-valid current set and rechecks on its
  next request. A tenant created out of band — by another process, or direct
  SQL — heals on the first request that names it, within the rebuild interval.
- **Positive-set TTL** — the set is also rebuilt after a TTL even absent a miss;
  the backstop for out-of-band *drops* (a dropped name stays valid until the next
  rebuild — rebuild-on-miss only heals creates, not drops).
- **Lifecycle invalidation** — the set is updated when a tenant is created or
  dropped through `Apartment::Tenant`, *after* the operation succeeds: created
  names added, dropped names removed. `:create` is an existing adapter callback;
  `drop` is hooked via a new `:drop` callback or the existing `drop.apartment`
  `ActiveSupport::Notifications` event. In-process create/drop is immediate;
  cross-process changes heal via rebuild-on-miss (creates) or the TTL (drops).
  A create/drop that lands *during* a rebuild is captured and re-applied to the
  freshly built set, so the whole-set swap never silently discards it.
- **Thread- and fiber-safety** — the registry is process-global and read on
  every request across threads and fibers. The positive set is a
  `concurrent-ruby` set; a rebuild swaps in a whole new set under a state mutex,
  re-applying lifecycle deltas captured during the (unlocked) provider call. The
  built-in validator is itself memoized behind a mutex, so concurrent first
  access cannot construct (and leak) more than one. `Mutex` is owned per-fiber
  (Ruby 3.0+; apartment requires ≥ 3.3), so single-flight holds under a fiber
  scheduler as well as under threads, and every lock is released by the fiber
  that took it. Timestamps use `Process.clock_gettime(Process::CLOCK_MONOTONIC)`,
  consistent with `PoolManager`/`PoolReaper`.
- **Fail-open on source error** — if `tenants_provider` raises, *or returns a
  non-Enumerable* (e.g. `nil` from a misconfigured provider), the validator
  degrades: it allows every request rather than blanket-404ing the app, logged
  at `error` for operators to alert on. (Also correct at boot, before the tenant
  table exists.) A *successful* call returning an Enumerable that does not list
  the name is a real miss → 404 — including an empty `[]`, the right answer for a
  fresh install with no tenants. The `nil`-vs-`[]` distinction is deliberate:
  `[]` is "zero tenants," `nil` is "the provider didn't answer."

Defaults: positive-set TTL ~5 minutes, rebuild interval ~5–10s; both configurable.

### External schema provisioning

`Apartment::Tenant.create` / `.drop` publish `create.apartment` / `drop.apartment`
themselves, so the in-process validator picks them up for free. Apps that
provision tenants through some other path — raw `psql`, `pg_restore`, a separate
schema-cloning job, an out-of-band migration tool — bypass that publication and
fall back to rebuild-on-miss latency (one extra `tenants_provider` call per
process on the new tenant's first hit; *drops* linger until the TTL).

For zero-delay propagation in that case, instrument the matching event after
the schema is live:

```ruby
Apartment::Lifecycle.notify_created('acme')   # after the schema/db exists
Apartment::Lifecycle.notify_dropped('acme')   # after it's gone
```

These are thin wrappers over `ActiveSupport::Notifications.instrument` with the
event names the validator already subscribes to; calling them when the
lifecycle *did* go through `Apartment::Tenant` is redundant but harmless. They
are in-process only — multi-process propagation is still the next section's
problem.

### Multi-process deployments

The registry is per-process. With several app processes or containers, a
`Tenant.create` in one process does not reach the others' registries directly —
but rebuild-on-miss heals it: the first request naming the new tenant on any
process rebuilds that process's set. A *dropped* tenant lingers in other
processes' sets until their TTL; a request to it in that window degrades to the
pre-existing behavior (a database error), not a data leak.

The gem ships **no cache backend**. An app needing strict cross-process
consistency plugs a custom `tenant_validator` backed by a **dedicated,
un-namespaced store**. Tenant validity is *global* data, so it must not go
through a `Rails.cache` that is namespaced per tenant (a common multi-tenant
setup) — that fragments one global registry across tenant namespaces. Use a
keyspace keyed purely by tenant name. Strict, immediate cross-process *drop*
enforcement specifically needs that custom validator (with its own pub/sub or
version key); the in-process default does not guarantee it.

### Configuration

```ruby
Apartment.configure do |config|
  # Validation (on by default — uses the built-in TenantValidator):
  #   config.tenant_validator = false   # disable entirely
  #   config.tenant_validator = Apartment::TenantValidator.new(positive_ttl: 600)
  #   # custom — note a bare callable runs on EVERY request, so it must do its
  #   # own memoizing / caching; do not put an unmemoized DB query here:
  #   config.tenant_validator = MyTenantValidator.new

  # Response on a miss (default: raise Apartment::TenantNotFound):
  #   config.tenant_not_found_handler = ->(tenant, request) {
  #     [302, { 'Location' => 'https://example.com' }, []]
  #   }
end
```

### Railtie

The railtie registers:

```ruby
ActionDispatch::ExceptionWrapper.rescue_responses['Apartment::TenantNotFound'] = :not_found
```

So when no `tenant_not_found_handler` is configured, an unknown tenant raises
`TenantNotFound`, and Rails renders the application's own 404 (`public/404.html`
or its dynamic equivalent) — zero config, the app's real error page, and the
exception stays honest and catchable. An app can override the mapping or set a
handler for a custom response.

### Scope

The check lives in `Generic`, so all six elevators inherit it: `Subdomain`,
`FirstSubdomain`, `Domain`, `Host`, `Header`, `HostHash`. `HostHash`'s
resolution-time `TenantNotFound` routes through the same handler (see the flow
above).

## Edge cases

- **`parse_tenant_name` returns `nil`** (no subdomain, excluded subdomain) — no
  switch, request runs in the default tenant. Unchanged; not a not-found case.
- **Resolved name equals `default_tenant`** — always valid; never sent to the
  registry.
- **Malformed name** — a structurally invalid name simply is not in the valid
  set → treated as not-found (404). No separate 400 path; format validation
  remains the adapter's concern (`TenantNameValidator`).
- **Known tenant, database unavailable** — not a not-found case. The validator
  passes (the name is valid); a genuine connection error surfaces as before.
  Validation does not mask infrastructure failure.
- **`Header` elevator** — validation confirms a resolved header value is a real
  tenant; it does **not** establish trust. Header trust remains infrastructure's
  responsibility (`trusted:` option).

## Breaking change

On-by-default validation changes observable behavior: an unknown subdomain that
previously produced a deep 500 now produces `TenantNotFound` → 404. v4 is in the
alpha line, where behavior changes are expected; it ships with a breaking-change
note in `docs/upgrading-to-v4.md`. Apps depending on the old behavior set
`config.tenant_validator = false`.

## Testing

- **Unit — `TenantValidator`**: positive-set hit, lazy build, rebuild-on-miss
  heals a name added to the source, rebuild-on-miss is rate-limited (a second
  miss inside the interval does not re-hit the source), single-flight (concurrent
  misses trigger one rebuild), positive-set TTL refresh, `Tenant.create`/`drop`
  lifecycle invalidation, fail-open when `tenants_provider` raises or returns a
  non-Enumerable (and an empty `[]` is *not* a failure — it 404s). The
  validator's registry is process-global, so its specs reset it per example
  (mirroring the pinned-model registry pattern documented in `spec/CLAUDE.md`).
- **Unit — `Generic`/elevators**: valid name → `switch`; invalid → handler called
  with `(name, request)`; invalid + no handler → raises `TenantNotFound`; `nil`
  name → no switch; `default_tenant` → valid; `HostHash` miss → handler path.
- **Unit — railtie**: `rescue_responses['Apartment::TenantNotFound']` registered.
- **Integration** (`spec/integration/v4/`): request to an unknown subdomain →
  404 (not 500); custom `tenant_not_found_handler` → its response; disabled
  validator → switch proceeds.

## Out of scope

- **Multi-source tenant resolution** (header, custom domain, SSO param) — already
  `parse_tenant_name`'s job; customize by subclassing.
- **Validating programmatic `Tenant.switch('typo')`** — `switch` stays a thin
  context-setter usable from jobs, console, rake, and migrations; it is not made
  HTTP-aware or globally-validating. This feature is request-path only.
- **Distributed / shared-process cache** — the built-in cache is per-process.
  Apps needing cross-process invalidation plug a custom `tenant_validator`
  backed by their own cache.

## Alternatives considered

- **Validate inside `Tenant.switch`** — rejected. `switch` is used by non-request
  code (jobs, console, rake, migrations); making it validate globally or carry
  HTTP concerns is the wrong layer and would surprise non-request callers.
- **Validate in the adapter / on pool creation** — rejected. The database is the
  ground truth, but this preserves the "fail on first query" timing and has no
  Rack request for a redirect or rendered response.
- **Opt-in validator (default off)** — rejected. The gem's default experience
  would stay broken; the opaque 500 persists for anyone who does not opt in.
- **Unknown subdomain falls through to the default tenant** — rejected as a
  *default*. Silently serving the default tenant for a typo'd or hostile
  subdomain is a data-exposure footgun. It remains available to apps that want
  it via a `tenant_not_found_handler` that returns the default-tenant response.
- **Bare `[404, {}, …]` from the gem** — rejected in favor of raise +
  `rescue_responses` mapping, so the app's own 404 page renders instead of a
  gem-rendered body.
- **`Rails.cache`-backed validator as the built-in default** — rejected (a
  four-model panel review was unanimous): a network round-trip on every request,
  each request coupled to cache availability, and `Rails.cache` is not guaranteed
  to be a shared store. It stays available for opt-in via the `tenant_validator`
  seam — see [Multi-process deployments](#multi-process-deployments) for how to
  back one correctly.
- **A negative cache of confirmed-invalid names** — rejected. Once rebuild-on-miss
  is rate-limited, the rate limit alone bounds `tenants_provider` calls; a cache
  keyed by arbitrary unknown names adds no protection and is itself an
  unbounded-memory / DoS vector.
- **The positive set in `ActiveSupport::CurrentAttributes`** — rejected as a
  category error. `CurrentAttributes` is request-scoped: Rails resets it before
  and after every request, so the set would be wiped each request, collapsing the
  cache into a per-request query. `CurrentAttributes` is for the *current tenant*
  (`Apartment::Current`, per-request context); the *set of all valid tenants* is
  shared global data. The correct shape is process-global state behind a `Mutex`
  plus `concurrent-ruby` structures, as in `PoolManager` and `pinned_models`.
