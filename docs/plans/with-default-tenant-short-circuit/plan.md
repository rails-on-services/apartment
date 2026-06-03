# `with_default_tenant` Same-Tenant Short-Circuit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Skip the assign/restore work in `Apartment::Tenant.with_default_tenant` when `Current.tenant` is already exactly the default tenant, leaving `previous_tenant` untouched on that no-op self-entry.

**Architecture:** One guard line (`return yield if Current.tenant == default`) added after the `DefaultTenantNotConfigured` check and before the `begin/ensure`. The predicate reads **raw** `Current.tenant` (not effective `current`/`in_default_tenant?`), so the ambient-`nil` case still takes the full assign path and both guard axes (explicitness, identity) behave exactly as today. TDD: failing tests first, then the one-line guard, then doc updates.

**Tech Stack:** Ruby, RSpec, `ActiveSupport::CurrentAttributes` (`Apartment::Current`). Unit tests only — no database required (`bundle exec rspec spec/unit/`).

**Design spec:** `docs/designs/with-default-tenant-short-circuit.md`

---

## File structure

| File | Action | Responsibility |
|---|---|---|
| `spec/unit/tenant_spec.rb` | Modify | Add 3 specs to the existing `.with_default_tenant` describe block (short-circuit; ambient-nil still enters; real-tenant still enters) |
| `lib/apartment/tenant.rb` | Modify | Add the short-circuit guard + one-line comment to `with_default_tenant` |
| `docs/designs/tenant-aware-caching.md` | Modify | Note the same-default no-op in the `previous_tenant` sentence |

Reference (current `with_default_tenant`, `lib/apartment/tenant.rb:127-142`):

```ruby
def with_default_tenant
  raise(ArgumentError, 'Apartment::Tenant.with_default_tenant requires a block') unless block_given?

  default = Apartment.config&.default_tenant
  raise(Apartment::DefaultTenantNotConfigured) if default.nil?

  previous = Current.tenant
  begin
    Current.tenant = default
    Current.previous_tenant = previous
    yield
  ensure
    Current.tenant = previous
    Current.previous_tenant = nil
  end
end
```

The existing `.with_default_tenant` describe block is at `spec/unit/tenant_spec.rb:758-832`. In that file, `described_class` is `Apartment::Tenant` and `Apartment::Current` is referenced directly (see the existing `restores prior context (including nil) on raise` example at line 784). The default tenant configured in this spec context is `'public'`.

---

## Task 1: Pin the short-circuit and the raw-vs-identity boundary with tests

**Files:**
- Modify/Test: `spec/unit/tenant_spec.rb` (inside the `describe '.with_default_tenant'` block, after the existing `nests:` example ending at line 831)

- [ ] **Step 1: Add the three failing specs**

Insert these three examples immediately before the closing `end` of the `describe '.with_default_tenant'` block (i.e. after the `nests: restores each enclosing tenant context as blocks unwind` example, before line 832's `end`):

```ruby
    it 'short-circuits when already explicitly in the default, leaving previous_tenant untouched' do
      described_class.switch!('public')
      Apartment::Current.previous_tenant = 'sentinel'

      # The assign/restore branch is skipped: Current.tenant= is never called
      # during the no-op self-entry, so the sentinel previous_tenant survives.
      allow(Apartment::Current).to(receive(:tenant=).and_call_original)

      result = described_class.with_default_tenant do
        expect(described_class.current).to(eq('public'))
        :block_value
      end

      expect(result).to(eq(:block_value))
      expect(Apartment::Current).not_to(have_received(:tenant=))
      expect(Apartment::Current.previous_tenant).to(eq('sentinel'))
    end

    it 'still enters from ambient nil (raw predicate, not effective identity)' do
      Apartment::Current.tenant = nil

      described_class.with_default_tenant do
        # Proves we did NOT broaden to in_default_tenant?: from ambient nil the
        # full assign path runs, so the explicitness axis sees an entered tenant.
        expect(described_class.current).to(eq('public'))
        expect(described_class.tenant_switched?).to(be(true))
      end

      expect(Apartment::Current.tenant).to(be_nil)
    end

    it 'still enters from a real tenant and restores it on exit' do
      described_class.switch!('tenant1')

      described_class.with_default_tenant do
        expect(described_class.current).to(eq('public'))
      end

      expect(described_class.current).to(eq('tenant1'))
    end
```

- [ ] **Step 2: Run the new specs to verify the short-circuit one fails**

Run: `bundle exec rspec spec/unit/tenant_spec.rb -e 'with_default_tenant'`

Expected: the two "still enters …" examples PASS (current behavior already enters), and the **`short-circuits when already explicitly in the default …` example FAILS** — today `with_default_tenant` always calls `Current.tenant=` and resets `previous_tenant` to `nil`, so both `not_to have_received(:tenant=)` and `previous_tenant == 'sentinel'` fail.

- [ ] **Step 3: Commit the failing test**

```bash
git add spec/unit/tenant_spec.rb
git commit -m "Test: with_default_tenant short-circuits a same-default self-entry

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Add the short-circuit guard

**Files:**
- Modify: `lib/apartment/tenant.rb` (`with_default_tenant`, currently `lib/apartment/tenant.rb:127-142`)

- [ ] **Step 1: Insert the guard after the `DefaultTenantNotConfigured` check**

In `with_default_tenant`, between the `raise(Apartment::DefaultTenantNotConfigured) if default.nil?` line and the `previous = Current.tenant` line, add:

```ruby
        # Already explicitly in the default context — entering it again is a
        # no-op, so skip the assign/restore and leave previous_tenant untouched.
        # Raw equality (not in_default_tenant?): ambient nil still takes the full
        # path below, so tenant_switched? inside the block is unchanged.
        return yield if Current.tenant == default
```

The method body becomes:

```ruby
      def with_default_tenant
        raise(ArgumentError, 'Apartment::Tenant.with_default_tenant requires a block') unless block_given?

        default = Apartment.config&.default_tenant
        raise(Apartment::DefaultTenantNotConfigured) if default.nil?

        # Already explicitly in the default context — entering it again is a
        # no-op, so skip the assign/restore and leave previous_tenant untouched.
        # Raw equality (not in_default_tenant?): ambient nil still takes the full
        # path below, so tenant_switched? inside the block is unchanged.
        return yield if Current.tenant == default

        previous = Current.tenant
        begin
          Current.tenant = default
          Current.previous_tenant = previous
          yield
        ensure
          Current.tenant = previous
          Current.previous_tenant = nil
        end
      end
```

- [ ] **Step 2: Run the `.with_default_tenant` specs to verify all pass**

Run: `bundle exec rspec spec/unit/tenant_spec.rb -e 'with_default_tenant'`

Expected: ALL `.with_default_tenant` examples PASS — the three new ones plus the existing requires-a-block, runs-in-default, restore-on-exit, restore-on-raise, strict-mode-bypass, `DefaultTenantNotConfigured`, and nesting examples (the nesting example's inner call now short-circuits, and its `current`-based assertions still hold).

- [ ] **Step 3: Run the full tenant spec to check for regressions**

Run: `bundle exec rspec spec/unit/tenant_spec.rb`

Expected: PASS (no examples failing).

- [ ] **Step 4: Commit**

```bash
git add lib/apartment/tenant.rb
git commit -m "with_default_tenant: short-circuit a same-default self-entry

Skip the assign/restore (and leave previous_tenant untouched) when
Current.tenant already equals the default. Raw equality keeps the
ambient-nil case on the full path, so both guard axes are unchanged.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Update the tenant-aware-caching design note

**Files:**
- Modify: `docs/designs/tenant-aware-caching.md` (the `previous_tenant` sentence in §`with_default_tenant`, ~line 166-169)

- [ ] **Step 1: Amend the `previous_tenant` sentence**

Find this sentence (in the `#### with_default_tenant` subsection, around line 166-169):

```
restores it (including `nil`) in `ensure`, on both normal exit and raise. Nesting
restores `Current.tenant` to the enclosing value at each level; `Current.previous_tenant`
is reset to `nil` on exit (single-level, non-stacking — the same contract as the
existing `switch` primitives, not a deeper stack).
```

Replace it with:

```
restores it (including `nil`) in `ensure`, on both normal exit and raise. Nesting
restores `Current.tenant` to the enclosing value at each level; `Current.previous_tenant`
is reset to `nil` on exit (single-level, non-stacking — the same contract as the
existing `switch` primitives, not a deeper stack). As an optimization, a call made
while `Current.tenant` already equals the default is a no-op: it `yield`s in place
without re-assigning `Current.tenant` and leaves `previous_tenant` untouched (raw
equality, so ambient `nil` still enters the default normally).
```

- [ ] **Step 2: Verify no private-repo references and the link still resolves**

Run: `grep -n "default" docs/designs/tenant-aware-caching.md | grep -i "no-op"`
Expected: one line matching the new sentence (confirms the edit landed).

- [ ] **Step 3: Commit**

```bash
git add docs/designs/tenant-aware-caching.md
git commit -m "Docs: note with_default_tenant same-default no-op in caching design

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Lint and final verification

**Files:** none (verification only)

- [ ] **Step 1: Rubocop the changed Ruby files**

Run: `bundle exec rubocop lib/apartment/tenant.rb spec/unit/tenant_spec.rb`

Expected: no offenses. If `return yield if ...` trips a cop, autocorrect with `bundle exec rubocop -A lib/apartment/tenant.rb spec/unit/tenant_spec.rb` and re-run; re-inspect the diff to confirm the guard logic is unchanged.

- [ ] **Step 2: Run the full unit suite**

Run: `bundle exec rspec spec/unit/`

Expected: all examples PASS (0 failures).

- [ ] **Step 3: Confirm the branch is ready**

Run: `git log --oneline main..HEAD`

Expected: four commits — the design doc (already committed), the failing test, the guard, and the docs note. Branch `with-default-tenant-short-circuit` is ready to open a PR against `main`.

---

## Notes for the implementer

- **Default tenant is `'public'`** in `spec/unit/tenant_spec.rb`'s configured context; the existing examples (e.g. `runs the block in the default tenant`, line 770) rely on this. If a future config change moves it, the literals in Task 1 must move with it.
- **Why a spy on `Current.tenant=`** rather than asserting on `current` inside the block: from the default context, both the short-circuit path and the full path leave `current == 'public'` inside the block, so `current` alone cannot distinguish them. The `not_to have_received(:tenant=)` assertion is what actually proves the assign/restore branch was skipped. `previous_tenant == 'sentinel'` is the user-facing contract that proves the no-clobber behavior.
- **Do not** change `switch`, `switch!`, or `reset` — the short-circuit is scoped to `with_default_tenant` only (see the design spec's "Scope boundary").
- **Do not** use `in_default_tenant?` as the predicate — that is the rejected Option B and would flip `tenant_switched?` inside the block for ambient-`nil` callers.
