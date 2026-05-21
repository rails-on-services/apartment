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
  middleware-level. This design treats `v4-elevators.md`'s line as the error and
  resolves it (see [Resolving the doc contradiction](#resolving-the-doc-contradiction)).

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
built-in validator is used when unset. The default tenant is always treated as
valid — it is not an isolated tenant subject to the registry.

A `TenantNotFound` raised *during tenant resolution itself* — `HostHash` raises
it from `parse_tenant_name` on an unmapped host — is caught **narrowly around the
`@processor.call`** and routed through the same `handle_tenant_not_found` path,
so every elevator's not-found case flows through one handler. The rescue does
**not** wrap `@app.call`; a `TenantNotFound` raised by the application for its
own reasons is never swallowed.

### Built-in validator

`Apartment::TenantValidator` — a memoized registry, not a per-request
`tenants_provider` call. `tenants_provider` is the *source* of tenant names; it
may be a database query and must never run on every request.

- **Positive set** — a `Set` of valid tenant names, built lazily from
  `Apartment.tenant_names` on first use.
- **Negative cache** — names recently found invalid, with a short TTL. Without
  it, an attacker looping `random1.example.com`, `random2…` misses the positive
  set every time and hits the tenant source per junk request; the negative cache
  bounds that to one lookup per name per TTL window.
- **Positive-set TTL** — the positive set is rebuilt after a TTL elapses, a
  safety net for tenants created or dropped out of band (another process, direct
  SQL) that the in-process callbacks below never observed.
- **Lifecycle invalidation** — the validator updates its set when a tenant is
  created or dropped through `Apartment::Tenant`, via the adapter's lifecycle
  callbacks. A create/drop *in this process* updates the set immediately;
  out-of-band changes heal on the TTL. (`:create` is an existing adapter
  callback; a `:drop` hook is added if one does not already exist.)
- **Thread-safety** — the registry is process-global and read on every request
  across threads; backed by `concurrent-ruby` structures. Timestamps use
  `Process.clock_gettime(Process::CLOCK_MONOTONIC)`, consistent with
  `PoolManager`/`PoolReaper`.
- **Fail-open on source error** — if `tenants_provider` raises while the set is
  being built (e.g. the tenant table does not exist yet during initial setup),
  the validator logs a warning and treats the request as valid (the switch
  proceeds — today's behavior). Validation is a UX improvement; a flaky tenant
  source must not brick the whole application with blanket 404s. A *successful*
  provider call that simply does not contain the name is a real miss → 404.

TTL defaults: positive set 60s, negative cache 10s (negative kept short so a
genuinely new tenant is not rejected for long). Both configurable on the
validator.

### Configuration

```ruby
Apartment.configure do |config|
  # Validation (on by default — uses the built-in TenantValidator):
  #   config.tenant_validator = false                      # disable entirely
  #   config.tenant_validator = ->(name) { Account.exists?(subdomain: name) }  # custom
  #   config.tenant_validator = Apartment::TenantValidator.new(positive_ttl: 300)

  # Response on a miss (default: raise Apartment::TenantNotFound):
  #   config.tenant_not_found_handler = ->(tenant, request) {
  #     [302, { 'Location' => 'https://example.com' }, []]
  #   }
end
```

`tenant_validator`: `nil` (unset) → built-in validator; `false` → validation
disabled; a callable (or any object responding to `call`) → used as-is.

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

The check lives in `Generic`, so every name-resolving elevator inherits it:
`Subdomain`, `FirstSubdomain`, `Domain`, `Host`, `Header`. `HostHash` already
raises `TenantNotFound` on an unmapped host; it is routed through the same
handler (above) rather than left as a parallel path.

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

## Resolving the doc contradiction

`docs/designs/v4-elevators.md` and `docs/designs/apartment-v4.md` are updated so
both describe the elevator-level handler consistently. `v4-elevators.md`'s "Error
Handling" section — currently stating Generic does not rescue and the handler is
adapter-level — is rewritten to describe the `tenant_validator` /
`tenant_not_found_handler` seams.

## Breaking change

On-by-default validation changes observable behavior: an unknown subdomain that
previously produced a deep 500 now produces `TenantNotFound` → 404. v4 is in the
alpha line, where behavior changes are expected; this ships with a CHANGELOG
entry. Apps depending on the old behavior set `config.tenant_validator = false`.

## Testing

- **Unit — `TenantValidator`**: positive-set hit, negative-cache hit, lazy build,
  positive-set TTL refresh, negative-cache TTL expiry, `Tenant.create`/`drop`
  lifecycle invalidation, fail-open when `tenants_provider` raises,
  thread-safety smoke. The validator's registry is process-global, so its specs
  reset it per example (mirroring the pinned-model registry pattern documented
  in `spec/CLAUDE.md`).
- **Unit — `Generic`/elevators**: valid name → `switch`; invalid → handler called
  with `(name, request)`; invalid + no handler → raises `TenantNotFound`; `nil`
  name → no switch; `default_tenant` → valid; `HostHash` miss → handler path.
- **Unit — railtie**: `rescue_responses['Apartment::TenantNotFound']` registered.
- **Integration** (`spec/integration/v4/`): request to an unknown subdomain →
  404 (not 500); custom `tenant_not_found_handler` → its response; disabled
  validator → switch proceeds.

## Out of scope

- **Multi-source tenant resolution** (header / custom domain / SSO param) — that
  is `parse_tenant_name`'s job and already customizable by subclassing.
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
