# Plan — Default-tenant guardrails (explicit base-schema semantics)

Tracks issue [#393](https://github.com/rails-on-services/apartment/issues/393). Adds guardrails around `Apartment.config.default_tenant` so apps can opt out of the implicit-public model that produces order-dependent test flake and "I created a record but `each` doesn't see it" surprise. Single PR off `main`.

## Goal

Close the asymmetry where `Tenant.current` falls back to `default_tenant` (read-side implicit) while `Tenant.each` excludes it (write-side excluded). The fix is two cheap predicates plus one configurable guard — not a rename, not a strict-mode rewrite, not a deprecation cycle.

## Non-goals

- Renaming `default_tenant` to `base_schema`. The existing name spans `:schema` (PG) and `:database` (MySQL); `base_schema` is PG-specific and worse.
- Changing `Tenant.current`'s fallback semantics. Logging, query tags, and Sentry breadcrumbs depend on a String return; returning `nil` would regress those.
- An iterable-default flag (`base_schema_iterable`). Cleanup helpers stop needing default sweeps once the guards land; defer until a real use case appears.
- Excluded-models behavior. `excluded_models` is already shimmed into `pinned_models` at `Tenant.init` time and is orthogonal to this work.

## Public API

```ruby
# Predicate: was a tenant explicitly entered?
Apartment::Tenant.switched?            # => true | false

# Test-time assertion: raise when no explicit tenant is active
Apartment::Tenant.assert_inside_tenant!

# Config: guard explicit switches into the default tenant
Apartment.configure do |config|
  config.default_tenant_switch_allowed = false  # raises on switch(default_tenant)
end
```

`Tenant.reset` continues to use `switch!` (no block, no guard) — it remains the legitimate path back to the default tenant under the strict default.

## Strategy-keyed defaults

The pathology the issue describes is a PostgreSQL-`:schema` artifact: the `public` schema is simultaneously AR's default and Apartment's shared store. MySQL `:database` and PG `:database_name` don't have that overlap. Defaults reflect that:

| Strategy | `default_tenant` default | `default_tenant_switch_allowed` default |
|---|---|---|
| `:schema` (PostgreSQL) | `'public'` | `false` |
| `:database` (MySQL) | `nil` | `true` (no-op when default is nil) |
| `:database_name` (PostgreSQL) | `nil` | `true` (no-op when default is nil) |

When `default_tenant` is `nil`, the guard is inert — no real `switch(name)` argument matches `nil`. MySQL apps that explicitly set a `default_tenant` opt into the strict default if they also set `default_tenant_switch_allowed = false`; otherwise they get permissive behavior.

## Implementation surface

### `lib/apartment/config.rb`

Add the attribute, defaults, validation:

```ruby
attr_accessor :default_tenant_switch_allowed
# initialize:
@default_tenant_switch_allowed = nil
# apply_defaults!:
if @default_tenant_switch_allowed.nil?
  @default_tenant_switch_allowed = (@tenant_strategy != :schema)
end
# validate!:
unless [true, false].include?(@default_tenant_switch_allowed)
  raise(ConfigurationError,
        "default_tenant_switch_allowed must be true or false, got: #{@default_tenant_switch_allowed.inspect}")
end
```

### `lib/apartment/tenant.rb`

Three additions:

```ruby
# Guard inside switch (block form only — switch! stays unguarded so reset works)
def switch(tenant, &block)
  raise(ArgumentError, 'Apartment::Tenant.switch requires a block') unless block

  cfg = Apartment.config
  if cfg && !cfg.default_tenant_switch_allowed && tenant.to_s == cfg.default_tenant.to_s
    raise(Apartment::ApartmentError,
          "switch(#{cfg.default_tenant.inspect}) is disabled by default_tenant_switch_allowed = false. " \
          'Use Apartment::Tenant.reset for explicit re-entry into the default tenant.')
  end

  # ... existing body ...
end

def switched?
  !Current.tenant.nil?
end

def assert_inside_tenant!
  return if switched?

  raise(Apartment::ApartmentError,
        'Expected an explicit tenant context, but Apartment::Current.tenant is nil. ' \
        'Wrap the call in Apartment::Tenant.switch(tenant) { ... } or call Apartment::Tenant.switch!(tenant).')
end
```

`switched?` reads `Current.tenant` directly — *not* `Tenant.current`. That's the semantic distinction: "did someone explicitly enter a tenant" is different from "what tenant is effectively active right now."

`reset` is unchanged — it calls `switch!`, which never enters the guarded path.

### `lib/apartment/errors.rb`

No new error class; reuses `Apartment::ApartmentError`. The message is the discriminator.

### Generator template

`lib/generators/apartment/install/templates/apartment.rb` gets a commented line:

```ruby
# Strict default for PostgreSQL :schema strategy. Set to true to allow
# Apartment::Tenant.switch(default_tenant) { ... }; reset is always allowed.
# config.default_tenant_switch_allowed = false
```

## Implementation phasing

One PR, three commits, in this order:

### Commit 1 — Predicates and assertion (no behavior change)

- `lib/apartment/tenant.rb` — add `switched?` and `assert_inside_tenant!`. Pure additions; no existing call sites change.
- Specs in `spec/unit/tenant_spec.rb`.

Ships first because it's risk-free and lets test suites adopt `assert_inside_tenant!` immediately, even before commit 2 lands.

### Commit 2 — Config flag + switch guard

- `lib/apartment/config.rb` — attribute, defaults keyed on strategy, validation.
- `lib/apartment/tenant.rb` — guard inside `switch` block form. `switch!` stays unguarded.
- Generator template comment.
- Specs:
  - `spec/unit/config_spec.rb` — strategy-keyed defaults, validation.
  - `spec/unit/tenant_spec.rb` — guard raises under strict; permits when allowed; `reset` always works; `switch!(default_tenant)` always works.

### Commit 3 — Documentation

- `docs/architecture.md` — short section on the default-tenant contract: AR base pool, holds pinned tables, in PG search path, never iterated by `each`.
- `lib/apartment/CLAUDE.md` — note on the new predicates and the strategy-keyed default.
- `CHANGELOG.md` — single entry describing the breaking default for `:schema` apps and the migration path (`config.default_tenant_switch_allowed = true` to keep v3 behavior).

## Test plan

### Unit

- `Tenant.switched?` returns false when `Current.tenant` is nil; true after `switch!('a')`; false after `reset`; true inside a `switch(...) { }` block; false outside.
- `Tenant.assert_inside_tenant!` raises with a helpful message when `Current.tenant` is nil; no-ops when switched.
- Strategy-keyed defaults: `:schema` → `default_tenant_switch_allowed == false`; `:database` → `true`; explicit override (either direction) wins over strategy default.
- Guard:
  - `switch('public') { }` raises under `:schema` defaults.
  - `switch('public') { }` permitted when `default_tenant_switch_allowed = true`.
  - `switch!('public')` permitted regardless.
  - `Tenant.reset` permitted regardless (proves `reset` uses `switch!`).
  - Guard is inert when `default_tenant` is nil (MySQL with no override).
  - Guard does not trigger for non-default tenants.
- Validation: non-boolean `default_tenant_switch_allowed` raises `ConfigurationError`.

### Integration

No new integration specs required. Existing `spec/integration/v4/` suites should pass unchanged because:
- `Tenant.reset` is unguarded, and the suites use it (or `switch!`) for setup/teardown.
- No test calls `switch('public') { }` directly today (verified via grep before merging).

If the grep turns up such call sites in fixtures or shared examples, those become migration touchpoints in the same PR.

### Manual

- `bin/dev/test-strict-default` smoke: configure `default_tenant_switch_allowed = false`, attempt `switch('public') { }` — confirms the error message points at `reset`.

## Migration notes (for the CHANGELOG)

For PG `:schema` apps upgrading to v4 with this change:

```ruby
# Restore v3 / pre-#393 behavior:
Apartment.configure do |config|
  config.default_tenant_switch_allowed = true
end
```

For test suites adopting the strict default, a one-liner in the suite's `rails_helper.rb`:

```ruby
RSpec.configure do |c|
  c.before(:each, type: :tenant_scoped) { Apartment::Tenant.assert_inside_tenant! }
end
```

(or unconditionally in suites where every example must run inside a real tenant).

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Existing PG apps that do `switch('public') { … }` for shared work break on upgrade | CHANGELOG migration note + strategy-keyed default makes the change loud, not silent. The error message points at `reset`. |
| Confusion between `Tenant.switched?` (raw) and `Tenant.current` (effective with fallback) | Document both in `docs/architecture.md`; `switched?` body is one line so the semantics stay legible. |
| `assert_inside_tenant!` over-fires in app code that legitimately runs in default | It's opt-in. No automatic wiring. Apps choose where to call it. |
| MySQL apps with custom `default_tenant` get permissive default unexpectedly | Documented in the generator template + CHANGELOG. Setting `default_tenant_switch_allowed = false` is one line. |

## Open questions

- Should `Tenant.assert_inside_tenant!` accept an optional message argument for richer test failures? Defer; add when a caller asks.
- Should we surface a Rails generator (`bin/rails g apartment:strict_tenancy`) that wires the RSpec hook? Defer; one-line copy-paste is cheap.

## Status

- [ ] Commit 1 — predicates and assertion
- [ ] Commit 2 — config flag and switch guard
- [ ] Commit 3 — documentation and CHANGELOG
- [ ] Open PR off `main`
