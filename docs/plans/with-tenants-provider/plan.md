# Plan — `Apartment::Tenant.with_tenants_provider` + `with_tenants`

Tracks issue [#390](https://github.com/rails-on-services/apartment/issues/390). Adds a block-scoped override for the resolver that produces the tenant list. Single PR off `main`.

## Goal

Block-scoped primitive that overrides `config.tenants_provider` for the duration of a block, applied uniformly at every "what tenants do we have?" call site. Production semantics unchanged when no block is active.

## Public API

```ruby
# Mechanism: swap the resolver. Accepts callable or coerce-to-Array(String|Symbol).
Apartment::Tenant.with_tenants_provider(source) { ... }

# Convenience: enumerated list (splat). Delegates to with_tenants_provider.
Apartment::Tenant.with_tenants(*names) { ... }
```

Accepted shapes for `source`:

| Input | Coerced to |
|---|---|
| Object responding to `:call` | kept as-is (re-evaluated on each `tenant_names` access in scope) |
| String / Symbol | `Array(source).map(&:to_s).freeze` |
| Array of String/Symbol | `source.map(&:to_s).freeze` |

`with_tenants(*names)` is `with_tenants_provider(names, &block)` — splat avoids the `with_tenants(['a'])` vs `with_tenants('a')` ambiguity.

## Scope: every call site, one resolver

`Apartment.tenant_names` becomes the single resolver. The Enumerable check moves up so it applies to both the ambient `tenants_provider` and per-block overrides. Five call sites that currently call `config.tenants_provider.call` directly are rerouted:

| File:line | Current | After |
|---|---|---|
| `lib/apartment/schema_cache.rb:18` | `Apartment.config.tenants_provider.call.map { ... }` | `Apartment.tenant_names.map { ... }` |
| `lib/apartment/migrator.rb:66` | `tenants = Apartment.config.tenants_provider.call` | `tenants = Apartment.tenant_names` |
| `lib/apartment/cli/seeds.rb:32` | `tenants = Apartment.config.tenants_provider.call` | `tenants = Apartment.tenant_names` |
| `lib/apartment/cli/tenants.rb:40` | `Apartment.config.tenants_provider.call.each { say(t) }` | `Apartment.tenant_names.each { say(t) }` |
| `lib/apartment/cli/tenants.rb:59` | `tenants = Apartment.config.tenants_provider.call` | `tenants = Apartment.tenant_names` |
| `lib/apartment/cli/migrations.rb:82` | `tenants = Apartment.config.tenants_provider.call` | `tenants = Apartment.tenant_names` |

`Tenant.fetch_tenant_list` (private helper in `lib/apartment/tenant.rb`) collapses into `Apartment.tenant_names`. `Tenant.each` becomes `Apartment.tenant_names.each { ... }` when no explicit list is passed.

## Mechanism

`Current.tenant_override` lives on `Apartment::Current` (`ActiveSupport::CurrentAttributes`). Fiber-safe, auto-reset per Rails request, propagates through ActiveJob — strict upgrade over the `Thread.current` sketch in the issue body.

```ruby
# lib/apartment/current.rb
class Current < ActiveSupport::CurrentAttributes
  attribute :tenant, :previous_tenant, :migrating, :tenant_override
end
```

## Implementation phasing

One PR, three commits, in this order:

### Commit 1 — Reroute call sites through `Apartment.tenant_names`

Refactor only. No behavior change. Pulls the Enumerable check up into the resolver and updates the five direct call sites + `Tenant.fetch_tenant_list`.

- `lib/apartment.rb` — `tenant_names` becomes the canonical resolver. Validates `respond_to?(:each)` on the resolved value.
- `lib/apartment/tenant.rb` — drop `fetch_tenant_list`, point `each` at `Apartment.tenant_names`.
- Five rerouted files above.

Tests that already exercise `each` and `tenant_names` should pass unchanged. Add a test that proves `tenant_names` raises on non-Enumerable returns from `tenants_provider` (currently only `Tenant.each` does this; the new resolver makes it uniform).

### Commit 2 — Add `Current.tenant_override` and the public methods

- `lib/apartment/current.rb` — add the `:tenant_override` attribute.
- `lib/apartment/tenant.rb` — add `with_tenants_provider(source)` and `with_tenants(*names)` as public class methods on the `<< self` block.
- `lib/apartment.rb` — `tenant_names` reads `Current.tenant_override` first; falls back to `@config.tenants_provider`. Same Enumerable check.

### Commit 3 — Specs

- `spec/unit/tenant_spec.rb` — block primitive specs.
- `spec/unit/apartment_spec.rb` — resolver specs (override wins, callable override re-evaluates, ambient when no override).

## Test plan

Unit (`spec/unit/`):

- `with_tenants_provider` accepts a callable; resolver invokes it on each `tenant_names` access inside the block.
- `with_tenants_provider` coerces String → `[String]`, Symbol → `[String]`, `[String, Symbol]` → `[String, String]`, all frozen.
- `with_tenants(*names)` delegates: `with_tenants('a', 'b')` ≡ `with_tenants_provider(['a', 'b'])`.
- Empty array override (`with_tenants` with no args) yields zero iterations through `Tenant.each`. `[]` is distinguishable from `nil`.
- Nesting: inner override fully replaces outer for the inner block, outer restored after inner returns.
- Ensure-restore: raise inside the block restores `Current.tenant_override` to its previous value.
- Override applies at every rerouted call site: `Apartment.tenant_names`, `Tenant.each`, `Migrator#run` (smoke check that it consumes the override list), `SchemaCache.dump_all` (smoke), CLI commands skipped (covered by integration if needed).
- Non-callable, non-coercible input (e.g., `Object.new`) — raises `ArgumentError` from `with_tenants_provider`. (Or is silently coerced via `Array(...)` → `[]`? Decide in implementation; `Array()` is permissive but masks bugs. Lean toward explicit raise.)
- Callable override that returns a non-Enumerable raises `ConfigurationError` with the same message shape as `tenants_provider`.
- Block-not-given raises `ArgumentError`.
- Fiber isolation: `Fiber.new { Current.tenant_override }` inside the block sees `nil` (CurrentAttributes is fiber-local).

Integration: not required for this change — the override is a pure-Ruby resolver swap with no DB interaction.

## Out of scope (deferred)

- ActiveJob propagation tests — needs the host-app railtie test infra; tracked separately in `docs/designs/v4-railtie-test-infra.md`.
- RSpec metadata helper (`describe MyJob, tenants: [...]`) — host-side, not gem-side.
- Validation against ambient `tenants_provider` — explicitly rejected (issue body argues this).
- `config.skip_missing_schemas` — explicitly rejected (silent skipping in production is a footgun).

## Backward compatibility

All public surface is additive. Existing `Tenant.each(tenants)` with explicit list arg continues to work; the override only kicks in when no list is passed *and* `Current.tenant_override` is set. No deprecation, no breaking change.

## Estimated size

~30 lines of implementation + ~150 lines of spec. Single PR, mergeable into `main`, included in next alpha cut.
