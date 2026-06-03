# `with_default_tenant` same-tenant short-circuit

**Status:** Implemented (PR #432)
**Scope:** `Apartment::Tenant.with_default_tenant` (one guard line + tests)
**Related:** [[tenant-aware-caching]] (the guard family this method belongs to), `lib/apartment/tenant.rb`

## TL;DR

When `with_default_tenant` is called while `Current.tenant` is *already* the
default, skip the enter/restore work and `yield` in place. The predicate reads
**raw** `Current.tenant` (not effective `current`), `to_s`-normalized like the
sibling guards (`Current.tenant.to_s == default.to_s`), so it is a pure no-op
elimination: no guard, on either axis, changes meaning. The one observable effect
— a no-op self-entry no longer clobbers `Current.previous_tenant` — is the
intended, more-correct contract and is pinned by a test.

## Motivation

`with_default_tenant` unconditionally assigns `Current.tenant = default`, runs the
block, and restores in `ensure`. When the caller is already in the default
context, that assign/restore pair is wasted work.

The cost is negligible **in this gem**: v4 switching is a single in-memory
`CurrentAttributes` assignment, no SQL. The short-circuit matters for a v3-shaped
consumer where entering the default issues a `SET search_path` round-trip. A
pinned-data cache wrapper that runs on the request hot path (reading global keys in
the default keyspace on every request) would otherwise carry its own
`return yield if Apartment::Tenant.current == default` guard to stay SQL-free.
Pushing the equivalent guard into apartment lets that optimization live in one
place so consumers can stay dumb. The benefit is real on v3 and harmless on v4.

## Design

### The change

Add one guard at the top of `with_default_tenant`, after the
`DefaultTenantNotConfigured` check and before the `begin/ensure`:

```ruby
default = Apartment.config&.default_tenant
raise(Apartment::DefaultTenantNotConfigured) if default.nil?

# Already explicitly in the default context — entering it again is a no-op,
# so skip the assign/restore (and leave previous_tenant untouched). to_s
# normalization matches the sibling guards (symbol/string default).
return yield if Current.tenant.to_s == default.to_s

previous = Current.tenant
begin
  Current.tenant = default
  Current.previous_tenant = previous
  yield
ensure
  Current.tenant = previous
  Current.previous_tenant = nil
end
```

### Why raw `Current.tenant`, not effective identity

The predicate reads **raw** `Current.tenant`, not `in_default_tenant?` (effective
`current`). This is deliberate and is the crux of the design. It is `to_s`-normalized
on both sides — matching `in_default_tenant?` / `require_default_tenant!` /
`guard_default_tenant_switch!`, which all compare `…to_s == default.to_s` because
`default_tenant` is a plain accessor that accepts a symbol or a string — but "raw"
here means it reads `Current.tenant` directly, *not* the `Current.tenant || default`
fallback. `nil.to_s` is `''`, which never equals a (validated non-empty) default, so
normalization does not pull the ambient-`nil` case into the short-circuit.

Apartment's guards split into two axes (the `#427` model):

- **Explicitness** — `tenant_switched?`, reads raw `Current.tenant`: "did code
  *explicitly enter* a tenant?"
- **Identity** — `in_default_tenant?`, reads effective `current` (`Current.tenant
  || default`): "what tenant is *effectively active*?"

The two predicates diverge only when `Current.tenant` is `nil` (ambient context —
boot, console, an unswitched job): raw equality says "not the default"
(`nil != 'public'`); identity says "the default" (the `nil → default` fallback).

| Starting `Current.tenant` | Raw equality (chosen) | Effective identity (rejected) |
|---|---|---|
| `'tenant1'` (real tenant) | enters default | enters default |
| `'public'` (explicit default) | **skips** | **skips** |
| `nil` (ambient) | enters default | **skips** |

Choosing raw equality keeps the ambient-`nil` case on the full assign path, so
inside the block `Current.tenant` is `'public'` and `tenant_switched?` is `true` —
identical to today. An effective-identity predicate would short-circuit ambient
`nil`, leaving `Current.tenant == nil` inside the block: `tenant_switched?` would
flip to `false` and `assert_tenant_switched!` would raise where it passes today.
That silently breaks the explicitness axis for a benefit v4 doesn't have. Rejected.

### `previous_tenant` contract (the one observable difference)

Today, entering the default *while already explicitly in the default* sets
`Current.previous_tenant = 'public'` for the block's duration, then resets it to
`nil` on exit. The short-circuit skips that branch, so `previous_tenant` retains
whatever value it held before the call.

This is the intended contract: a no-op self-entry should not disturb the
preceding-tenant marker. It is consistent with the documented "single-level,
non-stacking, immediately-preceding" semantics of `previous_tenant` — there is no
meaningful "previous" when you never actually moved. A test pins this behavior so
it is a decision, not an accident.

### No `ensure` on the short-circuit path — relies on block-form discipline

The short-circuit returns before the `begin/ensure`, so it does not restore
`Current.tenant` after the block. That is sound because the block form
`switch(t) { }` restores any context it enters via its own `ensure` — the
universal contract in this codebase — so a best-practice block leaves the default
intact. The only way to leak is a non-block mutation inside the block (`switch!`,
raw `Current.tenant =`); both are discouraged anti-patterns, and the alternative
(wrapping the short-circuit in its own restoring `ensure`) would add machinery
purely to protect code that shouldn't exist. A positive test pins the block-form
case; the method comment names the assumption. The panel review (Codex, Cursor)
raised this edge; the resolution is to keep the short-circuit and document the
contract rather than defend the anti-pattern.

### Scope boundary

`with_default_tenant` only. `switch` is untouched: it is the general-purpose path,
its self-entry into the default is already gated by `guard_default_tenant_switch!`
(strict mode), and changing its `previous_tenant` handling would alter the contract
the migrator and elevators depend on. `switch!` and `reset` are likewise unchanged.

## Testing

Add to the `.with_default_tenant` describe block in `spec/unit/tenant_spec.rb`:

1. **Short-circuits when already explicitly in the default.** `switch!('public')`,
   set a sentinel `Current.previous_tenant`, call `with_default_tenant { ... }`,
   and assert the block ran in `'public'` *and* `previous_tenant` is unchanged
   (i.e. the assign/restore branch was skipped). A spy on `Current.tenant=`
   confirming zero calls during the block is the tightest assertion.
2. **Still enters from ambient `nil` (proves raw, not identity).** `Current.tenant
   = nil`; inside the block `current == 'public'` and `tenant_switched?` is `true`;
   after, `Current.tenant` is `nil` again.
3. **Still enters from a real tenant.** `switch!('tenant1')`; inside the block
   `current == 'public'`; after, `current == 'tenant1'`.
4. **Existing tests stay green** unchanged: requires-a-block, restore-on-raise
   (including `nil`), strict-mode bypass, `DefaultTenantNotConfigured`, and the
   nesting test (`tenant_spec.rb:818`) — whose inner `with_default_tenant` now
   short-circuits, and whose `current`-based assertions still hold.

## Documentation

- One-line note in the `with_default_tenant` method comment (the short-circuit and
  the `previous_tenant` no-clobber behavior).
- Update the `previous_tenant` sentence in `docs/designs/tenant-aware-caching.md`
  (§`with_default_tenant`, ~line 167) to note that a same-default self-entry is a
  no-op that leaves `previous_tenant` untouched.
- No README or `docs/caching.md` change: the public contract (enter default,
  restore on exit) is unchanged for every caller that wasn't already in the
  default.

## Alternatives considered

- **Effective-identity predicate (`in_default_tenant?`).** Broader skip (covers
  ambient `nil`, the v3 elevator hot path), but flips `tenant_switched?` inside the
  block and breaks the explicitness axis. Rejected — see above.
- **Do nothing; document the asymmetry.** Defensible, since v4's assign is already
  free and a v3 consumer deletes its own fallback at cutover. Rejected because the
  guard is one cheap, harmless line that lets the optimization live at the right
  altitude (in apartment, not duplicated in every consumer's cache wrapper).
- **Short-circuit `switch` too.** Out of scope and riskier: `switch` is
  strict-mode-gated and its `previous_tenant` handling is load-bearing for the
  migrator. Not pursued.
