# Plan — Default-tenant guardrails (explicit base-schema semantics)

Tracks issue [#393](https://github.com/rails-on-services/apartment/issues/393). Adds opt-in guardrails around `Apartment.config.default_tenant` so apps can elect explicit base-schema semantics without the v4 default changing for everyone. Single PR off `main`.

## Goal

Close the asymmetry where `Tenant.current` falls back to `default_tenant` (read-side implicit) while `Tenant.each` excludes it (write-side excluded). The fix is two cheap predicates plus one **opt-in** configurable guard — not a rename, not a strict-mode rewrite, not a default behavior change.

## Non-goals

- Renaming `default_tenant` to `base_schema`. The existing name spans `:schema` (PG) and `:database` (MySQL); `base_schema` is PG-specific and worse.
- Changing `Tenant.current`'s fallback semantics. Logging, query tags, and Sentry breadcrumbs depend on a String return; returning `nil` would regress those.
- An iterable-default flag (`base_schema_iterable`). Cleanup helpers stop needing default sweeps once apps adopt the guards; defer until a real use case appears.
- Excluded-models behavior. `excluded_models` is already shimmed into `pinned_models` at `Tenant.init` time and is orthogonal to this work.
- **A `Tenant.in_default_tenant { ... }` block API.** Deferred. Only justified if `default_tenant_switch_allowed = false` becomes the default (it doesn't, see below). Under the permissive default, `switch(default_tenant) { ... }` already works for the same use case.
- **Cross-pool transaction visibility in tests.** Documented as a constraint of pool-per-tenant; not solved at the API level. Apps mixing transactional fixtures with cross-pool reads must use deletion strategies.

## What changed after the downstream consumer briefing

A v4 alpha consumer surfaced six asks. Panel review (Codex + Cursor) narrowed the upstream-appropriate scope:

| Ask | Verdict | Where |
|---|---|---|
| `Tenant.switched?` | In | Commit 1 |
| `Tenant.assert_inside_tenant!` | In | Commit 1 |
| `assert_inside_tenant!(message:)` kwarg | In | Commit 2 |
| `default_tenant_switch_allowed` flag | In, **default true everywhere** | Commit 2 |
| `Tenant.in_default_tenant { ... }` block API | Deferred | — |
| `switch!` stance clarification | In, doc-only | Commit 3 |
| Cross-pool transaction visibility | Doc constraint, no API | Commit 3 |
| `clean_excluded_models!` helper | Doc recipe, no helper | Commit 3 |
| `tenant_names` memoization | Rejected (violates callable contract) | — |
| `Tenant.create` + PG 17 `\restrict` | Separate issue, requires non-CampusESP reproducer | Follow-up |

The strict-mode default flip was the biggest change. The consumer's actual flake came from wrapping in `switch('test-tenant')`, not `switch('public')` — so a `:schema`-strict default wouldn't have prevented their bug. Breaking v3 semantics by default needs a broader failure mode than one app's test discipline. Strict mode stays opt-in.

## Public API

```ruby
# Predicate: was a tenant explicitly entered?
# Reads Current.tenant directly (NOT Tenant.current); ignores the
# default_tenant fallback.
Apartment::Tenant.switched?            # => true | false

# Test-time assertion: raise when no explicit tenant is active.
# Optional message: kwarg for richer failure context.
Apartment::Tenant.assert_inside_tenant!
Apartment::Tenant.assert_inside_tenant!(message: 'this spec must declare a tenant')

# Config: opt-in guard on switch(default_tenant) { ... }
Apartment.configure do |config|
  config.default_tenant_switch_allowed = false  # raises on switch(default_tenant)
end
```

`Tenant.reset` and `Tenant.switch!` continue to work without the guard — they remain the path back to the default tenant under strict mode. `switch(default_tenant) { ... }` is the only call shape the guard intercepts.

## Defaults

`default_tenant_switch_allowed` defaults to **`true` for all strategies**. Existing v4 alpha apps see no behavior change. Strict mode is opt-in:

```ruby
# Recommended for new PG :schema apps that want strict tenant discipline:
config.default_tenant_switch_allowed = false
```

When `default_tenant` is `nil` (current default for `:database` strategies), the guard is inert — no real `switch(name)` argument matches `nil`. So setting `default_tenant_switch_allowed = false` on MySQL is a safe no-op until the app also sets a `default_tenant`.

## Implementation surface

### `lib/apartment/config.rb`

```ruby
attr_accessor :default_tenant_switch_allowed
# initialize:
@default_tenant_switch_allowed = nil
# apply_defaults!:
@default_tenant_switch_allowed = true if @default_tenant_switch_allowed.nil?
# validate!:
unless [true, false].include?(@default_tenant_switch_allowed)
  raise(ConfigurationError,
        "default_tenant_switch_allowed must be true or false, got: #{@default_tenant_switch_allowed.inspect}")
end
```

### `lib/apartment/tenant.rb`

Two changes (commit 1 already added `switched?` and `assert_inside_tenant!`):

```ruby
# Guard inside switch (block form only — switch! and reset stay unguarded)
def switch(tenant, &block)
  raise(ArgumentError, 'Apartment::Tenant.switch requires a block') unless block

  cfg = Apartment.config
  if cfg && !cfg.default_tenant_switch_allowed &&
     cfg.default_tenant && tenant.to_s == cfg.default_tenant.to_s
    raise(Apartment::ApartmentError,
          "switch(#{cfg.default_tenant.inspect}) is disabled by default_tenant_switch_allowed = false. " \
          'Use Apartment::Tenant.reset for explicit re-entry into the default tenant, ' \
          'or Apartment::Tenant.switch!(name) for non-block scopes.')
  end

  # ... existing body unchanged ...
end

# Update assert_inside_tenant! to accept an optional message
def assert_inside_tenant!(message: nil)
  return if switched?

  raise(Apartment::ApartmentError,
        message ||
        'Expected an explicit tenant context, but Apartment::Current.tenant is nil. ' \
        'Wrap the call in Apartment::Tenant.switch(tenant) { ... } or call ' \
        'Apartment::Tenant.switch!(tenant).')
end
```

`reset` and `switch!` are unchanged — neither enters the guarded path.

### `lib/apartment/errors.rb`

No new error class; reuses `Apartment::ApartmentError`.

### Generator template

`lib/generators/apartment/install/templates/apartment.rb`:

```ruby
# Strict tenant discipline. When false, Apartment::Tenant.switch(default_tenant) { ... }
# raises — forces apps to use Tenant.reset or Tenant.switch! for explicit
# re-entry into the default tenant. Recommended for new PostgreSQL :schema
# apps. Defaults to true for backward compatibility.
# config.default_tenant_switch_allowed = false
```

## Implementation phasing

One PR, three commits, in this order:

### Commit 1 — Predicates and assertion *(done — 3cfcd0d)*

- `lib/apartment/tenant.rb` — `switched?` and `assert_inside_tenant!` added.
- `spec/unit/tenant_spec.rb` — 9 specs covering both predicates.

### Commit 2 — Config flag + switch guard + message kwarg

- `lib/apartment/config.rb` — `default_tenant_switch_allowed` attribute, default `true`, validation.
- `lib/apartment/tenant.rb` — guard inside `switch` block form; `assert_inside_tenant!` gains `message:` kwarg.
- Generator template comment.
- Specs:
  - `spec/unit/config_spec.rb` — default true regardless of strategy; explicit override; validation.
  - `spec/unit/tenant_spec.rb` — guard raises when strict; permits when allowed; `reset` always works; `switch!(default_tenant)` always works; guard inert when `default_tenant` is nil; `assert_inside_tenant!(message:)` uses custom message.

### Commit 3 — Documentation

- `docs/architecture.md` — section on the default-tenant contract: AR base pool, holds pinned tables, in PG search path, never iterated by `each`.
- `docs/testing.md` (new file) — three sections:
  1. **Strict tenant discipline** — `default_tenant_switch_allowed = false` + `assert_inside_tenant!` recipe.
  2. **`switch` vs `switch!` vs `reset`** — when each is right; explicit "switch! is not deprecated, use it for non-block scopes like `before(:context)`".
  3. **Cross-pool transaction visibility constraint** — pool-per-tenant means writes in one pool's transaction aren't visible to another pool's connection. For specs that need cross-pool reads, use deletion strategies (DatabaseCleaner `:deletion` or `:truncation`) rather than transactional fixtures. Document an example pattern; do not provide an API.
  4. **Cleaning shared (default) tenant data between specs** — recipe for iterating `Apartment.pinned_models` and `DELETE`-ing in tests; do not provide a helper method.
- `lib/apartment/CLAUDE.md` — note the new predicates, config flag default, and link to `docs/testing.md`.
- `CHANGELOG.md` — single entry: new opt-in guard, no breaking change.

## Test plan

### Unit

- `Tenant.switched?` (commit 1, done): false when nil; true after `switch!`; true after `reset` (reset is explicit entry); true inside `switch(...) { }`; false outside.
- `Tenant.assert_inside_tenant!`: raises when nil with default message; no-ops when switched; honors `message:` kwarg.
- `Config.default_tenant_switch_allowed`: defaults to `true` for all strategies; honors explicit override (true/false); validation rejects non-boolean.
- Guard:
  - `switch('public') { }` permitted under default (`= true`).
  - `switch('public') { }` raises when `default_tenant_switch_allowed = false` and `default_tenant = 'public'`.
  - `switch!('public')` permitted regardless.
  - `Tenant.reset` permitted regardless (uses `switch!`).
  - Guard inert when `default_tenant` is nil even with `= false`.
  - Guard does not trigger for non-default tenants.

### Integration

No new integration specs required. Grep verified zero `switch('public')` or `switch(default_tenant)` call sites in `lib/` or `spec/` (run on `main` before commit 1). Existing suites pass unchanged at default settings.

## Migration notes (for the CHANGELOG)

No migration needed. The default behavior is unchanged. Apps wanting strict discipline:

```ruby
Apartment.configure do |config|
  config.default_tenant_switch_allowed = false
end
```

For test suites adopting strict mode:

```ruby
RSpec.configure do |c|
  c.before(:each) { Apartment::Tenant.assert_inside_tenant! }
end
```

(or scoped via metadata where appropriate).

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Strict-mode error message confuses callers | Message points at `reset` and `switch!` as the alternatives. |
| `Current.tenant` vs `Tenant.current` keeps confusing readers | `docs/architecture.md` documents the distinction; `switched?` body is one line so semantics stay legible. |
| Apps adopt strict mode and discover `before(:context)` doesn't fit a block | `docs/testing.md` documents `switch!` as the recommended pattern for non-block scopes. |
| Cross-pool tx visibility footgun keeps surfacing | `docs/testing.md` documents the constraint plainly; no API change. |

## Follow-up issues to file

These came out of the consumer briefing but don't belong in this PR:

1. **`Tenant.create` reliability on Rails 7.1+ / PG 17 with `structure.sql`.** Needs a non-CampusESP reproducer before any API change. File as a bug with their `with_ddl_connection` workaround attached as context.
2. **Optional `apartment-rspec` companion gem.** If multiple apps surface needs around `clean_pinned_models!`, a `before(:tenant_scoped)` hook helper, etc. — defer until a second app asks.

Both are explicit follow-ups; this PR ships the smallest-coherent slice.

## Status

- [x] Commit 1 — predicates and assertion
- [ ] Commit 2 — config flag, switch guard, message kwarg
- [ ] Commit 3 — documentation (architecture, testing, CHANGELOG)
- [ ] Open PR off `main`
