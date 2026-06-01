# Tenant-Aware Caching & Tenant-Context Guards Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship issue #427 in one PR: a unified tenant-context guard family on `Apartment::Tenant` plus user-facing tenant-aware caching docs, so non-request code (jobs, rake, cable) fails loudly instead of silently contaminating another tenant's cache keyspace.

**Architecture:** All new methods are pure context reads/writes on the existing `Apartment::Tenant` facade (`lib/apartment/tenant.rb`), backed by `ActiveSupport::CurrentAttributes` (`Apartment::Current`). Two axes: explicitness (`tenant_switched?` / `assert_tenant_switched!`, renamed from `inside_tenant?` / `assert_inside_tenant!`) reads raw `Current.tenant`; identity (`in_tenant?` / `require_tenant!`, `in_default_tenant?` / `require_default_tenant!`) reads effective `Tenant.current`. A `cache_namespace` helper and a `with_default_tenant { }` block round out the surface. Three new exceptions in `lib/apartment/errors.rb`. Caching is documentation-only — Apartment owns the discipline, not the store.

**Tech Stack:** Ruby, RSpec (`spec/unit/`, no database needed), RuboCop. Reference design: `docs/designs/tenant-aware-caching.md`.

---

## File Structure

- `lib/apartment/errors.rb` — add `TenantRequired`, `DefaultTenantRequired`, `DefaultTenantNotConfigured`.
- `lib/apartment/tenant.rb` — rename two methods; add `in_tenant?`, `in_default_tenant?`, `require_tenant!`, `require_default_tenant!`, `cache_namespace`, `with_default_tenant`.
- `spec/unit/tenant_spec.rb` — rename two describe blocks; add describe blocks for the new methods.
- `docs/caching.md` — NEW user-facing guide (routed-vs-pinned, two-store architecture, guards, footguns).
- `docs/testing.md`, `docs/upgrading-to-v4.md`, `lib/apartment/CLAUDE.md` — update for the rename + new guard family.
- `CLAUDE.md` (project root) — add a Key Patterns line for tenant-aware caching.
- `README.md` — link the new caching guide if a caching section is absent.

**Leave alone:** `docs/plans/default-tenant-guardrails/plan.md` references the old names but is an archival record of past work; do not rewrite history.

**Reference — current `lib/apartment/tenant.rb` shape:** `switch` (line 12), `switch!` (31), `current` (37: `Current.tenant || Apartment.config&.default_tenant`), `reset` (42), `inside_tenant?` (55: `!Current.tenant.nil?`), `assert_inside_tenant!` (62, takes `message:` kwarg), then `init`/lifecycle. Private `guard_default_tenant_switch!` (179) compares with `to_s`. `Apartment::Current` (`lib/apartment/current.rb`) has attributes `:tenant, :previous_tenant, :migrating, :tenant_override`.

---

## Task 1: Add the three exception classes

**Files:**
- Modify: `lib/apartment/errors.rb` (append before the closing `end` of `module Apartment`, after `PendingMigrationError`, line 81)
- Test: `spec/unit/errors_spec.rb` (create if absent; otherwise append)

- [ ] **Step 1: Write the failing test**

Create or append to `spec/unit/errors_spec.rb`:

```ruby
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe('Apartment tenant-context errors') do
  describe Apartment::TenantRequired do
    it 'is an ApartmentError and names the effective tenant' do
      err = described_class.new('public')
      expect(err).to(be_a(Apartment::ApartmentError))
      expect(err.current).to(eq('public'))
      expect(err.message).to(match(/non-default tenant/))
      expect(err.message).to(match(/"public"/))
    end
  end

  describe Apartment::DefaultTenantRequired do
    it 'is an ApartmentError and names expected default vs actual' do
      err = described_class.new('acme', 'public')
      expect(err).to(be_a(Apartment::ApartmentError))
      expect(err.current).to(eq('acme'))
      expect(err.default).to(eq('public'))
      expect(err.message).to(match(/"public"/))
      expect(err.message).to(match(/"acme"/))
    end
  end

  describe Apartment::DefaultTenantNotConfigured do
    it 'is an ApartmentError with a configuration message' do
      err = described_class.new
      expect(err).to(be_a(Apartment::ApartmentError))
      expect(err.message).to(match(/default_tenant/))
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/unit/errors_spec.rb -f progress`
Expected: FAIL with `uninitialized constant Apartment::TenantRequired`.

- [ ] **Step 3: Add the exception classes**

In `lib/apartment/errors.rb`, insert after `PendingMigrationError`'s closing `end` (line 81), before the module's closing `end`:

```ruby
  # Raised by Apartment::Tenant.require_tenant! when the effective tenant is the
  # default (or unset) — routed data must not land in the default keyspace.
  class TenantRequired < ApartmentError
    attr_reader :current

    def initialize(current = nil)
      @current = current
      super(
        "Expected an explicit, non-default tenant context, but the effective " \
        "tenant is #{current.inspect}. Wrap the work in " \
        "Apartment::Tenant.switch(name) { ... } — routed data must not use the " \
        'default keyspace.'
      )
    end
  end

  # Raised by Apartment::Tenant.require_default_tenant! when the effective tenant
  # is a real (non-default) tenant — pinned/global work must run in the default.
  class DefaultTenantRequired < ApartmentError
    attr_reader :current, :default

    def initialize(current = nil, default = nil)
      @current = current
      @default = default
      super(
        "Expected the default tenant #{default.inspect}, but the effective " \
        "tenant is #{current.inspect}. Wrap pinned/global work in " \
        'Apartment::Tenant.with_default_tenant { ... }.'
      )
    end
  end

  # Raised by Apartment::Tenant.require_default_tenant! when no default_tenant is
  # configured: a pinned keyspace needs an explicitly named anchor, not nil.
  class DefaultTenantNotConfigured < ApartmentError
    def initialize(message = nil)
      super(
        message ||
        'require_default_tenant! needs a configured Apartment.config.default_tenant; ' \
        'none is set. A pinned keyspace requires an explicitly named default tenant.'
      )
    end
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/unit/errors_spec.rb -f progress`
Expected: PASS (3 examples).

- [ ] **Step 5: Commit**

```bash
git add lib/apartment/errors.rb spec/unit/errors_spec.rb
git commit -m "Add tenant-context guard exceptions (#427)"
```

---

## Task 2: Rename `inside_tenant?` / `assert_inside_tenant!` → `tenant_switched?` / `assert_tenant_switched!`

Clean rename, no aliases (pre-1.0 alpha). Explicitness axis unchanged — still reads raw `Current.tenant`.

**Files:**
- Modify: `lib/apartment/tenant.rb:46-70` (the two methods + their doc comments)
- Modify: `spec/unit/tenant_spec.rb:113-178` (the two describe blocks)

- [ ] **Step 1: Update the spec describe blocks to the new names**

In `spec/unit/tenant_spec.rb`, change `describe '.inside_tenant?'` (line 113) to `describe '.tenant_switched?'` and replace every `inside_tenant?` inside it with `tenant_switched?`. Change `describe '.assert_inside_tenant!'` (line 149) to `describe '.assert_tenant_switched!'` and replace every `assert_inside_tenant!` with `assert_tenant_switched!`. Add a guard example confirming the old names are gone — append inside the renamed `.tenant_switched?` block:

```ruby
    it 'no longer responds to the pre-rename names (no aliases)' do
      expect(described_class).not_to(respond_to(:inside_tenant?))
      expect(described_class).not_to(respond_to(:assert_inside_tenant!))
    end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/unit/tenant_spec.rb -e tenant_switched -f progress`
Expected: FAIL with `NoMethodError: undefined method 'tenant_switched?'`.

- [ ] **Step 3: Rename the methods in `tenant.rb`**

Replace `inside_tenant?` (lines 46-57) and `assert_inside_tenant!` (lines 59-70). The doc comments must move with them (Serena's symbol body excludes the leading comment — edit comment + body together). New text:

```ruby
      # Predicate: was a tenant explicitly entered? (Explicitness axis.)
      # Reads Current.tenant directly (not Tenant.current) so it does NOT
      # consider the default_tenant fallback. Use this when "did this code
      # explicitly enter a tenant?" matters more than "what tenant is
      # effectively active?" — typically test setup and assertion code.
      #
      # Note: after Tenant.reset, tenant_switched? returns true. reset enters the
      # default tenant via switch!, which is an explicit entry.
      def tenant_switched?
        !Current.tenant.nil?
      end

      # Raise if no tenant has been explicitly entered. (Explicitness axis.)
      # Test-time discipline for suites that want to fail loudly when ambient
      # writes would land in the default tenant. No-op when a tenant is active.
      def assert_tenant_switched!(message: nil)
        return if tenant_switched?

        raise(Apartment::ApartmentError,
              message ||
              'Expected an explicit tenant context, but Apartment::Current.tenant is nil. ' \
              'Wrap the call in Apartment::Tenant.switch(tenant) { ... } or call ' \
              'Apartment::Tenant.switch!(tenant).')
      end
```

- [ ] **Step 4: Catch any stragglers repo-wide**

Run: `grep -rn "inside_tenant?\|assert_inside_tenant!" --include=*.rb --include=*.md lib/ spec/ docs/testing.md docs/upgrading-to-v4.md README.md`
Expected after edits: only matches inside `docs/designs/tenant-aware-caching.md` (intended — it documents the rename) remain in scope. Update any hit in `lib/apartment/CLAUDE.md` (the `tenant.rb` section names both methods) to the new names. (Docs `testing.md` / `upgrading-to-v4.md` are rewritten in Task 8; a quick name swap now keeps the grep clean — acceptable either way.)

- [ ] **Step 5: Run the renamed specs**

Run: `bundle exec rspec spec/unit/tenant_spec.rb -f progress`
Expected: PASS (no `inside_tenant?` failures).

- [ ] **Step 6: Commit**

```bash
git add lib/apartment/tenant.rb spec/unit/tenant_spec.rb lib/apartment/CLAUDE.md
git commit -m "Rename inside_tenant?/assert_inside_tenant! to tenant_switched?/assert_tenant_switched! (#427)"
```

---

## Task 3: Add identity predicates `in_tenant?` / `in_default_tenant?`

Effective-`Tenant.current` semantics, `to_s`-normalized. `in_default_tenant?` is **false when no default is configured** (don't claim to be in a default that doesn't exist).

**Files:**
- Modify: `lib/apartment/tenant.rb` (insert after `assert_tenant_switched!`)
- Test: `spec/unit/tenant_spec.rb` (new describe block)

- [ ] **Step 1: Write the failing test**

Append to `spec/unit/tenant_spec.rb` (before the final `end`):

```ruby
  describe '.in_tenant? / .in_default_tenant? (identity axis)' do
    it 'A. forgot to switch (inertia -> default): not in tenant, in default' do
      Apartment::Current.reset
      expect(described_class.in_tenant?).to(be(false))
      expect(described_class.in_default_tenant?).to(be(true))
    end

    it 'B. explicit switch!(default): not in tenant, in default' do
      described_class.switch!('public')
      expect(described_class.in_tenant?).to(be(false))
      expect(described_class.in_default_tenant?).to(be(true))
    end

    it 'C. real tenant: in tenant, not in default' do
      described_class.switch!('tenant1')
      expect(described_class.in_tenant?).to(be(true))
      expect(described_class.in_default_tenant?).to(be(false))
    end

    it 'normalizes symbols against the configured default' do
      described_class.switch!(:public)
      expect(described_class.in_tenant?).to(be(false))
      expect(described_class.in_default_tenant?).to(be(true))
    end

    it 'in_default_tenant? is false when no default_tenant is configured' do
      Apartment.configure do |c|
        c.tenant_strategy = :database_name
        c.tenants_provider = -> { %w[tenant1] }
        c.default_tenant = nil
      end
      Apartment.adapter = mock_adapter
      Apartment::Current.reset
      expect(described_class.in_default_tenant?).to(be(false))
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/unit/tenant_spec.rb -e "identity axis" -f progress`
Expected: FAIL with `undefined method 'in_tenant?'`.

- [ ] **Step 3: Implement the predicates**

In `lib/apartment/tenant.rb`, insert after `assert_tenant_switched!`:

```ruby
      # Predicate: is the effective tenant a real, NON-default tenant?
      # (Identity axis — reads Tenant.current, default fallback included.)
      def in_tenant?
        c = current
        !c.nil? && c.to_s != Apartment.config&.default_tenant.to_s
      end

      # Predicate: is the effective tenant the default tenant?
      # (Identity axis.) False when no default_tenant is configured.
      def in_default_tenant?
        default = Apartment.config&.default_tenant
        !default.nil? && current.to_s == default.to_s
      end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/unit/tenant_spec.rb -e "identity axis" -f progress`
Expected: PASS (5 examples).

- [ ] **Step 5: Commit**

```bash
git add lib/apartment/tenant.rb spec/unit/tenant_spec.rb
git commit -m "Add in_tenant?/in_default_tenant? identity predicates (#427)"
```

---

## Task 4: Add raising guards `require_tenant!` / `require_default_tenant!`

Both return the normalized tenant name on success. `require_default_tenant!` raises `DefaultTenantNotConfigured` when no default is set.

**Files:**
- Modify: `lib/apartment/tenant.rb` (insert after `in_default_tenant?`)
- Test: `spec/unit/tenant_spec.rb` (new describe block)

- [ ] **Step 1: Write the failing test**

Append to `spec/unit/tenant_spec.rb`:

```ruby
  describe '.require_tenant! / .require_default_tenant! (raising guards)' do
    it 'require_tenant! returns the normalized name inside a real tenant' do
      described_class.switch!('tenant1')
      expect(described_class.require_tenant!).to(eq('tenant1'))
    end

    it 'require_tenant! raises TenantRequired on default-by-inertia' do
      Apartment::Current.reset
      expect { described_class.require_tenant! }
        .to(raise_error(Apartment::TenantRequired, /non-default tenant/))
    end

    it 'require_tenant! raises TenantRequired on explicit switch!(default)' do
      described_class.switch!('public')
      expect { described_class.require_tenant! }
        .to(raise_error(Apartment::TenantRequired))
    end

    it 'require_default_tenant! returns the default name when in default' do
      described_class.switch!('public')
      expect(described_class.require_default_tenant!).to(eq('public'))
    end

    it 'require_default_tenant! passes on default-by-inertia' do
      Apartment::Current.reset
      expect(described_class.require_default_tenant!).to(eq('public'))
    end

    it 'require_default_tenant! raises DefaultTenantRequired in a real tenant' do
      described_class.switch!('tenant1')
      expect { described_class.require_default_tenant! }
        .to(raise_error(Apartment::DefaultTenantRequired, /"public"/))
    end

    it 'require_default_tenant! raises DefaultTenantNotConfigured when no default set' do
      Apartment.configure do |c|
        c.tenant_strategy = :database_name
        c.tenants_provider = -> { %w[tenant1] }
        c.default_tenant = nil
      end
      Apartment.adapter = mock_adapter
      Apartment::Current.reset
      expect { described_class.require_default_tenant! }
        .to(raise_error(Apartment::DefaultTenantNotConfigured))
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/unit/tenant_spec.rb -e "raising guards" -f progress`
Expected: FAIL with `undefined method 'require_tenant!'`.

- [ ] **Step 3: Implement the guards**

In `lib/apartment/tenant.rb`, insert after `in_default_tenant?`:

```ruby
      # Guard: raise unless the effective tenant is a real, non-default tenant.
      # Returns the normalized tenant name on success (a documented convenience;
      # the cache recipe uses cache_namespace, not this return, for the proc).
      def require_tenant!
        return current.to_s if in_tenant?

        raise(Apartment::TenantRequired, current)
      end

      # Guard: raise unless the effective tenant is the default tenant. Returns
      # the normalized default name on success. Raises DefaultTenantNotConfigured
      # when no default_tenant is configured (a nil keyspace is a silent leak).
      def require_default_tenant!
        default = Apartment.config&.default_tenant
        raise(Apartment::DefaultTenantNotConfigured) if default.nil?
        return default.to_s if current.to_s == default.to_s

        raise(Apartment::DefaultTenantRequired.new(current, default))
      end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/unit/tenant_spec.rb -e "raising guards" -f progress`
Expected: PASS (7 examples).

- [ ] **Step 5: Commit**

```bash
git add lib/apartment/tenant.rb spec/unit/tenant_spec.rb
git commit -m "Add require_tenant!/require_default_tenant! guards (#427)"
```

---

## Task 5: Add `cache_namespace` helper

Value-returning wrapper over `require_tenant!` so the namespace proc reads honestly.

**Files:**
- Modify: `lib/apartment/tenant.rb` (insert after `require_default_tenant!`)
- Test: `spec/unit/tenant_spec.rb` (new describe block)

- [ ] **Step 1: Write the failing test**

Append to `spec/unit/tenant_spec.rb`:

```ruby
  describe '.cache_namespace' do
    it 'returns the normalized tenant name inside a real tenant' do
      described_class.switch!('tenant1')
      expect(described_class.cache_namespace).to(eq('tenant1'))
    end

    it 'raises TenantRequired outside a real tenant (fail-closed for the proc)' do
      Apartment::Current.reset
      expect { described_class.cache_namespace }
        .to(raise_error(Apartment::TenantRequired))
    end

    it 'works as a namespace proc' do
      proc = -> { described_class.cache_namespace }
      described_class.switch('tenant1') { expect(proc.call).to(eq('tenant1')) }
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/unit/tenant_spec.rb -e cache_namespace -f progress`
Expected: FAIL with `undefined method 'cache_namespace'`.

- [ ] **Step 3: Implement**

In `lib/apartment/tenant.rb`, insert after `require_default_tenant!`:

```ruby
      # Routed cache namespace helper: asserts a real, non-default tenant and
      # returns its normalized name. Intended as a fail-closed cache namespace
      # proc — `namespace: -> { Apartment::Tenant.cache_namespace }`.
      def cache_namespace
        require_tenant!
      end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/unit/tenant_spec.rb -e cache_namespace -f progress`
Expected: PASS (3 examples).

- [ ] **Step 5: Commit**

```bash
git add lib/apartment/tenant.rb spec/unit/tenant_spec.rb
git commit -m "Add cache_namespace routed-store helper (#427)"
```

---

## Task 6: Add `with_default_tenant { }` block

Enters the default tenant via the guard-exempt path (direct `Current.tenant` assignment, as `switch!`/`reset` do — bypasses `guard_default_tenant_switch!`), restores prior context (including `nil`) in `ensure`.

**Files:**
- Modify: `lib/apartment/tenant.rb` (insert after `cache_namespace`)
- Test: `spec/unit/tenant_spec.rb` (new describe block)

- [ ] **Step 1: Write the failing test**

Append to `spec/unit/tenant_spec.rb`:

```ruby
  describe '.with_default_tenant' do
    it 'requires a block' do
      expect { described_class.with_default_tenant }
        .to(raise_error(ArgumentError, /requires a block/))
    end

    it 'runs the block in the default tenant' do
      described_class.switch!('tenant1')
      described_class.with_default_tenant do
        expect(described_class.current).to(eq('public'))
        expect(described_class.in_default_tenant?).to(be(true))
      end
    end

    it 'restores the prior tenant on normal exit' do
      described_class.switch!('tenant1')
      described_class.with_default_tenant { :noop }
      expect(described_class.current).to(eq('tenant1'))
    end

    it 'restores prior context (including nil) on raise' do
      Apartment::Current.reset
      expect do
        described_class.with_default_tenant { raise('boom') }
      end.to(raise_error('boom'))
      expect(Apartment::Current.tenant).to(be_nil)
    end

    it 'bypasses the strict-mode default_tenant switch guard' do
      Apartment.configure do |c|
        c.tenant_strategy = :schema
        c.tenants_provider = -> { %w[tenant1] }
        c.default_tenant = 'public'
        c.default_tenant_switch_allowed = false
      end
      Apartment.adapter = mock_adapter
      Apartment::Current.reset
      expect { described_class.with_default_tenant { :ok } }.not_to(raise_error)
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/unit/tenant_spec.rb -e with_default_tenant -f progress`
Expected: FAIL with `undefined method 'with_default_tenant'`.

- [ ] **Step 3: Implement**

In `lib/apartment/tenant.rb`, insert after `cache_namespace`:

```ruby
      # Establish the default/pinned tenant context for the block, then restore
      # the prior context (including nil) on exit or raise. Enters default via
      # direct Current assignment — the guard-exempt path that reset/switch! use
      # — so it is NOT blocked by default_tenant_switch_allowed = false. Use for
      # pinned/global work (e.g. writing app-wide cache keys).
      def with_default_tenant
        raise(ArgumentError, 'Apartment::Tenant.with_default_tenant requires a block') unless block_given?

        previous = Current.tenant
        Current.tenant = Apartment.config&.default_tenant
        Current.previous_tenant = previous
        yield
      ensure
        Current.tenant = previous
        Current.previous_tenant = nil
      end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/unit/tenant_spec.rb -e with_default_tenant -f progress`
Expected: PASS (5 examples).

- [ ] **Step 5: Run the full tenant spec**

Run: `bundle exec rspec spec/unit/tenant_spec.rb -f progress`
Expected: PASS (all examples).

- [ ] **Step 6: Commit**

```bash
git add lib/apartment/tenant.rb spec/unit/tenant_spec.rb
git commit -m "Add with_default_tenant pinned-context block (#427)"
```

---

## Task 7: Write the user-facing caching guide

**Files:**
- Create: `docs/caching.md`

- [ ] **Step 1: Write `docs/caching.md`**

```markdown
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
- **Per-request `LocalCache`.** ActiveSupport's in-request memory layer keys by
  the namespace at access time; don't switch tenants mid-request around cached
  reads, or a stale tenant may be served from memory.
- **Fibers / `Thread.new`.** `Current` is fiber-local and does not propagate to a
  raw thread; re-establish context in the spawned execution.
- **`Rails.cache.clear`** on shared Redis wipes every tenant's keyspace. Prefer
  per-namespace expiry.
- **Org-level keys** (shared across a subset of tenants) are neither routed nor
  pinned — use an explicit `"org:#{org_id}"` namespace, not `Tenant.current`.
- **Job retries** must re-establish tenant context per `perform`.
```

- [ ] **Step 2: Verify it renders (no broken fences)**

Run: `grep -c '```' docs/caching.md`
Expected: an even number (all code fences closed).

- [ ] **Step 3: Commit**

```bash
git add docs/caching.md
git commit -m "Add user-facing tenant-aware caching guide (#427)"
```

---

## Task 8: Update existing docs and CLAUDE.md files

**Files:**
- Modify: `docs/testing.md` (the `assert_inside_tenant!` section, lines ~23-41 and ~171)
- Modify: `docs/upgrading-to-v4.md` (lines ~73-85)
- Modify: `lib/apartment/CLAUDE.md` (tenant.rb predicate section)
- Modify: `CLAUDE.md` (project root, Key Patterns)
- Modify: `README.md` (link the caching guide)

- [ ] **Step 1: Rename in `docs/testing.md`**

Replace the heading `### \`Tenant.assert_inside_tenant!\`` with `### \`Tenant.assert_tenant_switched!\``, and every `assert_inside_tenant!` / `inside_tenant?` in that file with `assert_tenant_switched!` / `tenant_switched?`. Update the prose sentence (line ~41) to: "`assert_tenant_switched!` reads `Current.tenant` directly, not `Tenant.current` — it answers \"did this spec explicitly enter a tenant?\", the explicitness axis."

- [ ] **Step 2: Rename + extend in `docs/upgrading-to-v4.md`**

Replace `inside_tenant?` → `tenant_switched?` and `assert_inside_tenant!` → `assert_tenant_switched!` (lines ~75-79). Add a short note after that block:

```markdown
v4 also adds the identity-axis guards for runtime (non-test) code:
`require_tenant!` / `require_default_tenant!`, predicates `in_tenant?` /
`in_default_tenant?`, `with_default_tenant { }`, and `cache_namespace`. See
[Tenant-Aware Caching](caching.md). `inside_tenant?` / `assert_inside_tenant!`
were renamed to `tenant_switched?` / `assert_tenant_switched!` with no aliases.
```

- [ ] **Step 3: Update `lib/apartment/CLAUDE.md`**

In the `tenant.rb — Public API` section, update the predicate bullets to the new names and add the identity-axis family:

```markdown
- **Explicitness axis** (raw `Current.tenant`): `tenant_switched?` /
  `assert_tenant_switched!(message:)`. Renamed from `inside_tenant?` /
  `assert_inside_tenant!` (no aliases).
- **Identity axis** (effective `Tenant.current`): `in_tenant?` / `require_tenant!`
  (real, non-default), `in_default_tenant?` / `require_default_tenant!` (default;
  raises `DefaultTenantNotConfigured` when no default set), `cache_namespace`
  (routed namespace proc helper), `with_default_tenant { }` (pinned context).
  See `docs/caching.md` and `docs/designs/tenant-aware-caching.md`.
```

- [ ] **Step 4: Add a Key Patterns line to project `CLAUDE.md`**

Under `## Key Patterns`, add:

```markdown
- **Tenant-aware caching** (design: `docs/designs/tenant-aware-caching.md`, guide:
  `docs/caching.md`): cache splits into routed (per-tenant, namespaced) vs pinned
  (global, never namespaced) — the same distinction `pin_tenant` draws for models.
  Guard non-request code with `Apartment::Tenant.require_tenant!` /
  `require_default_tenant!`; use the two-store recipe so pinned keys don't
  fragment across tenant keyspaces. Apartment owns the discipline, not the store.
```

- [ ] **Step 5: Link from `README.md`**

If the README has a docs/links section, add `- [Tenant-Aware Caching](docs/caching.md)`. If it has a caching section already, link the guide there. Otherwise add a one-line "Caching" subsection pointing at `docs/caching.md`. Run `grep -n -i "cache" README.md` first to find the right spot.

- [ ] **Step 6: Verify no stale names remain (outside the design doc)**

Run: `grep -rn "inside_tenant?\|assert_inside_tenant!" --include=*.rb --include=*.md lib/ spec/ docs/testing.md docs/upgrading-to-v4.md README.md CLAUDE.md`
Expected: no matches.

- [ ] **Step 7: Commit**

```bash
git add docs/testing.md docs/upgrading-to-v4.md lib/apartment/CLAUDE.md CLAUDE.md README.md
git commit -m "Update docs and CLAUDE.md for the guard family + caching guide (#427)"
```

---

## Task 9: Final verification and PR

- [ ] **Step 1: Run the full unit suite**

Run: `bundle exec rspec spec/unit/`
Expected: PASS, zero failures.

- [ ] **Step 2: Run RuboCop on every changed file**

Run: `bundle exec rubocop lib/apartment/errors.rb lib/apartment/tenant.rb spec/unit/tenant_spec.rb spec/unit/errors_spec.rb`
Expected: no offenses. Fix any before proceeding.

- [ ] **Step 3: Run the unit suite across Rails versions (sanity)**

Run: `bundle exec appraisal rails-8.1-sqlite3 rspec spec/unit/`
Expected: PASS. (Guards are pure context reads; this confirms no version drift.)

- [ ] **Step 4: Push and open the PR**

```bash
git push -u origin feat/tenant-aware-caching
gh pr create --base main \
  --title "Tenant-aware caching: routed/pinned cache guards + docs (#427)" \
  --body "Implements #427. Adds a unified tenant-context guard family on Apartment::Tenant (tenant_switched?/assert_tenant_switched! renamed from inside_tenant?/assert_inside_tenant!; in_tenant?/require_tenant!, in_default_tenant?/require_default_tenant!, cache_namespace, with_default_tenant) plus three exceptions and a user-facing caching guide (routed-vs-pinned, two-store architecture, footguns). Caching is docs-only — Apartment owns the discipline, not the store. Also removes a dead .mcp.json. Design: docs/designs/tenant-aware-caching.md.

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```

Expected: PR opened against `main`.

---

## Self-Review

**Spec coverage** (against `docs/designs/tenant-aware-caching.md`):
- Two axes / proof table → Tasks 2-4 (predicates + guards across the three states).
- Rename, no aliases → Task 2 (incl. a guard example asserting old names gone).
- `require_tenant!` / `require_default_tenant!` returning normalized names, `to_s` normalization → Tasks 3-4.
- `DefaultTenantNotConfigured` raise on nil default → Tasks 1, 4.
- `cache_namespace` split from the bang → Task 5.
- `with_default_tenant` state semantics + strict-mode bypass → Task 6.
- Three exception classes → Task 1.
- Two-store architecture + which-store-is-Rails.cache trade-off + footguns → Task 7.
- Doc/CLAUDE.md updates → Task 8.
- RuboCop on all changed files (per project rule) → Task 9.

**Refinement vs spec:** `in_default_tenant?` is implemented as **false** when no default is configured (cleaner than the literal `nil == nil`). The design doc was already corrected to match (committed alongside this plan), so no doc drift remains for the worker to reconcile.

**Placeholder scan:** none — every code/test step shows full content.

**Type/name consistency:** method names match across tasks (`cache_namespace`, `require_tenant!`, `tenant_switched?`); exception names match between Task 1 and their raise sites in Task 4; `DefaultTenantRequired.new(current, default)` arity matches the raise in Task 4.
