# Schema-Cache Recovery (Member 8) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `Apartment::Tenant.reload_schema_cache!` (a manual, current-process schema-cache recovery helper for the shared/pinned-table-DDL case) and fix the latent `schema_cache_per_tenant` load-path bug, closing the reactive half of failure-class member 8 for the v4 beta gate.

**Architecture:** The helper clears `pool.schema_cache` (`BoundSchemaReflection#clear!`, which lazy-repopulates from the DB on next access) across all warm tenant pools tracked by `PoolManager`, plus the default pool. The default pool is fetched via `with_default_tenant { ActiveRecord::Base.connection_pool }` because the ConnectionHandling patch would otherwise route `connection_pool` to a tenant pool. The bug fix replaces a call to the removed path-taking `load!` with the stable `pool.schema_reflection = SchemaReflection.new(path)` API.

**Tech Stack:** Ruby 3.3+, Rails 7.2/8.0/8.1 (ActiveRecord `SchemaReflection` / `BoundSchemaReflection` API), RSpec, RuboCop. No new dependencies.

## Global Constraints

- **Ruby** `>= 3.3`; **Rails** `7.2 / 8.0 / 8.1` (+ `main` canary). Code must pass on all.
- **RuboCop**: run `bundle exec rubocop` on every changed file (impl AND specs) before any push; zero new offenses.
- **No CampusESP/private references** in code, specs, comments, or commits — public OSS gem.
- **Branch**: work continues on `feat/v4-schema-cache-recovery` (already created off `main`, carries the design doc commit). One PR, squash-merged.
- **Helper is current-process only**; it never attempts cross-process invalidation (that stays the deferred transport seam).
- **Helper clears schema cache only** — never prepared statements (AR self-heals on PG).
- **Public API method**: `Apartment::Tenant.reload_schema_cache!(tenant = nil)` returning the integer count of pools cleared.

---

## File Structure

- `lib/apartment/patches/connection_handling.rb` — fix `load_tenant_schema_cache` (Task 1). (Modify)
- `lib/apartment/tenant.rb` — add `reload_schema_cache!(tenant = nil)` public method (Task 2). (Modify)
- `spec/unit/patches/connection_handling_spec.rb` — bug-fix round-trip test (Task 1). (Modify)
- `spec/unit/tenant_spec.rb` — helper contract tests with doubles (Task 2). (Modify)
- `docs/caching.md` — `## Schema-cache recovery` section (Task 3). (Modify)
- `docs/designs/fixture-pool-lifecycle.md` — mark member 8 reactive-half shipped (Task 3). (Modify)
- `docs/designs/v4-beta-readiness.md` — mark W2 shipped (Task 3). (Modify)

---

## Task 1: Fix the `schema_cache_per_tenant` load-path bug

**Files:**
- Modify: `lib/apartment/patches/connection_handling.rb` (`load_tenant_schema_cache`, currently lines 117-123)
- Test: `spec/unit/patches/connection_handling_spec.rb` (real-AR harness; `schema_cache_per_tenant` context near line 171)

**Interfaces:**
- Consumes: `Apartment::SchemaCache.cache_path_for(tenant) -> String`, `ActiveRecord::ConnectionAdapters::SchemaReflection.new(cache_path)`, `ConnectionPool#schema_reflection=`.
- Produces: a working `schema_cache_per_tenant: true` load path (no behavior consumed by later tasks).

- [ ] **Step 1: Write the failing test**

In `spec/unit/patches/connection_handling_spec.rb`, inside the `describe '#connection_pool'` block (alongside the existing `schema_cache_per_tenant` example near line 171), add:

```ruby
    context 'when schema_cache_per_tenant loads a real dump file' do
      around do |example|
        dir = Dir.mktmpdir
        @cache_path = File.join(dir, 'schema_cache_acme.yml')
        example.run
      ensure
        FileUtils.remove_entry(dir) if dir && File.directory?(dir)
      end

      it 'loads the per-tenant dump without raising (regression: BoundSchemaReflection#load! takes no args)' do
        # Warm acme's pool and dump its schema cache to a real file.
        Apartment::Current.tenant = 'acme'
        ActiveRecord::Base.connection.schema_cache.dump_to(@cache_path)
        # Force a fresh re-establish so the schema-cache load path runs on next resolve.
        role = ActiveRecord::Base.current_role
        Apartment.pool_manager.remove_tenant('acme')
        Apartment.deregister_shard("acme:#{role}")
        Apartment::Current.tenant = nil

        Apartment.configure do |config|
          config.tenant_strategy = :schema
          config.tenants_provider = -> { %w[acme widgets] }
          config.default_tenant = 'public'
          config.check_pending_migrations = false
          config.schema_cache_per_tenant = true
        end
        Apartment.adapter = mock_adapter
        allow(Apartment::SchemaCache).to(receive(:cache_path_for).with('acme').and_return(@cache_path))

        Apartment::Current.tenant = 'acme'
        expect { ActiveRecord::Base.connection_pool }.not_to(raise_error)
        pool = ActiveRecord::Base.connection_pool
        expect(pool.schema_reflection)
          .to(be_a(ActiveRecord::ConnectionAdapters::SchemaReflection))
      end
    end
```

Add `require 'tmpdir'` and `require 'fileutils'` at the top of the spec file if not already present (check the first ~5 lines; add only what's missing).

- [ ] **Step 2: Run the test to verify it fails**

```bash
bundle exec appraisal rails-8.1-sqlite3 rspec spec/unit/patches/connection_handling_spec.rb -e "loads the per-tenant dump without raising"
```
Expected: FAIL — `ActiveRecord::Base.connection_pool` raises `Apartment::ApartmentError` wrapping `ArgumentError: wrong number of arguments (given 1, expected 0)` from `pool.schema_cache.load!(cache_path)`.

- [ ] **Step 3: Apply the fix**

In `lib/apartment/patches/connection_handling.rb`, replace the body of `load_tenant_schema_cache`:

```ruby
      def load_tenant_schema_cache(tenant, pool)
        require_relative('../schema_cache')
        cache_path = Apartment::SchemaCache.cache_path_for(tenant)
        return unless File.exist?(cache_path)

        # Bind the pool's reflection to the dump file (Rails 7.1+ API). The
        # removed path-taking SchemaCache#load! raised ArgumentError here:
        # pool.schema_cache returns a BoundSchemaReflection whose #load! takes
        # no args. SchemaReflection.new(path) lazily loads the dump (and Rails
        # version-checks it, ignoring a stale file with a warning).
        pool.schema_reflection =
          ActiveRecord::ConnectionAdapters::SchemaReflection.new(cache_path)
      end
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bundle exec appraisal rails-8.1-sqlite3 rspec spec/unit/patches/connection_handling_spec.rb -e "loads the per-tenant dump without raising"
```
Expected: PASS.

- [ ] **Step 5: Run the full connection_handling spec (no regressions)**

```bash
bundle exec appraisal rails-8.1-sqlite3 rspec spec/unit/patches/connection_handling_spec.rb
```
Expected: all green (including the existing `deregisters the shard when a post-establish step raises` example, which mocks `cache_path_for` to raise and is unaffected by the load-mechanism change).

- [ ] **Step 6: RuboCop**

```bash
bundle exec rubocop lib/apartment/patches/connection_handling.rb spec/unit/patches/connection_handling_spec.rb
```
Expected: no offenses.

- [ ] **Step 7: Commit**

```bash
git add lib/apartment/patches/connection_handling.rb spec/unit/patches/connection_handling_spec.rb
git commit -m "Fix(v4): repair schema_cache_per_tenant load path (load! arity)

load_tenant_schema_cache called pool.schema_cache.load!(cache_path), but
pool.schema_cache returns a BoundSchemaReflection whose #load! takes no
arguments in Rails 7.2/8.0/8.1 — passing a path raised ArgumentError, so
schema_cache_per_tenant: true was latent-broken (default is false; the true
path had no real-file test). Use the stable schema_reflection= API. Add a
round-trip regression test that dumps a tenant cache and reloads it.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Add `Apartment::Tenant.reload_schema_cache!`

**Files:**
- Modify: `lib/apartment/tenant.rb` (add public method after `pool_stats`, ~line 294)
- Test: `spec/unit/tenant_spec.rb` (doubles-based contract tests)

**Interfaces:**
- Produces: `Apartment::Tenant.reload_schema_cache!(tenant = nil) -> Integer` (count of pools whose schema cache was cleared).
- Consumes: `Apartment.pool_manager` (responds to `each_pair { |key, pool| }`), `Apartment::Tenant.with_default_tenant { }` (yields in default-tenant context), `ActiveRecord::Base.connection_pool`, each pool's `schema_cache.clear!`.

- [ ] **Step 1: Write the failing tests**

In `spec/unit/tenant_spec.rb`, add a new top-level `describe` block (inside `RSpec.describe(Apartment::Tenant)`, e.g. after the `.switch` describe):

```ruby
  describe '.reload_schema_cache!' do
    let(:acme_cache)    { double('schema_cache', clear!: nil) }
    let(:widgets_cache) { double('schema_cache', clear!: nil) }
    let(:default_cache) { double('schema_cache', clear!: nil) }
    let(:acme_pool)     { double('pool', schema_cache: acme_cache) }
    let(:widgets_pool)  { double('pool', schema_cache: widgets_cache) }
    let(:default_pool)  { double('pool', schema_cache: default_cache) }
    let(:manager) do
      double('PoolManager').tap do |m|
        allow(m).to(receive(:each_pair)) do |&blk|
          blk.call('acme:writing', acme_pool)
          blk.call('widgets:writing', widgets_pool)
        end
      end
    end

    before do
      allow(Apartment).to(receive(:pool_manager).and_return(manager))
      # with_default_tenant yields in default context; stub it to just yield so
      # ActiveRecord::Base.connection_pool returns our default_pool double.
      allow(described_class).to(receive(:with_default_tenant)) { |&blk| blk.call }
      allow(ActiveRecord::Base).to(receive(:connection_pool).and_return(default_pool))
    end

    it 'clears the schema cache on every warm tenant pool and the default pool' do
      count = described_class.reload_schema_cache!
      expect(acme_cache).to(have_received(:clear!))
      expect(widgets_cache).to(have_received(:clear!))
      expect(default_cache).to(have_received(:clear!))
      expect(count).to(eq(3))
    end

    it 'scopes to a single tenant, leaving other tenant pools untouched' do
      count = described_class.reload_schema_cache!('acme')
      expect(acme_cache).to(have_received(:clear!))
      expect(widgets_cache).not_to(have_received(:clear!))
      # default pool is not a named real tenant, so it is excluded when scoping
      expect(default_cache).not_to(have_received(:clear!))
      expect(count).to(eq(1))
    end

    it 'includes the default pool when scoped to the default tenant' do
      count = described_class.reload_schema_cache!('public')
      expect(default_cache).to(have_received(:clear!))
      expect(acme_cache).not_to(have_received(:clear!))
      expect(count).to(eq(1))
    end

    it 'returns 0 and does not raise when no pool manager is configured' do
      allow(Apartment).to(receive(:pool_manager).and_return(nil))
      expect(described_class.reload_schema_cache!('acme')).to(eq(0))
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
bundle exec rspec spec/unit/tenant_spec.rb -e "reload_schema_cache!"
```
Expected: FAIL with `NoMethodError: undefined method 'reload_schema_cache!'`.

- [ ] **Step 3: Implement the method**

In `lib/apartment/tenant.rb`, add immediately after the `pool_stats` method (after its `end`, ~line 294, before `private`):

```ruby
      # Clear the schema cache on warm tenant pools (and the default pool) in
      # THIS PROCESS, so the next query re-reflects the database. Use after DDL
      # on a pinned/shared table (which N warm tenant pools may have cached) or
      # after manual DDL in a console. Lazy: clears now, repopulates from the DB
      # on next access (not from any dump file).
      #
      # Current-process only — it cannot reach other workers' pools; fleet-wide
      # DDL still needs a rolling restart. Clears schema reflection only, not
      # prepared statements (AR self-heals those on PostgreSQL) and not model
      # @columns_hash (call Model.reset_column_information or restart for that).
      # Not a linearized barrier: an in-flight request may use metadata it
      # already read. Intended for console / post-migrate / low-traffic use.
      #
      # tenant: nil clears all warm tenant pools + the default pool. A tenant
      # name clears only that tenant's warm pools (+ the default pool when the
      # name is the default tenant). Returns the count of pools cleared.
      def reload_schema_cache!(tenant = nil)
        pools = []

        Apartment.pool_manager&.each_pair do |key, pool|
          next if tenant && !key.start_with?("#{tenant}:")

          pools << pool
        end

        default = default_tenant
        if default && (tenant.nil? || tenant.to_s == default.to_s)
          # The ConnectionHandling patch routes connection_pool by Current.tenant;
          # enter default context so we get the real default pool, not a tenant one.
          # Guarded on `default` because with_default_tenant raises when no default
          # tenant is configured.
          default_pool = with_default_tenant { ActiveRecord::Base.connection_pool }
          pools << default_pool if default_pool
        end

        pools.each { |pool| pool.schema_cache.clear! }
        pools.size
      end
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
bundle exec rspec spec/unit/tenant_spec.rb -e "reload_schema_cache!"
```
Expected: PASS (all four examples).

- [ ] **Step 5: Run the full tenant spec (no regressions)**

```bash
bundle exec rspec spec/unit/tenant_spec.rb
```
Expected: all green.

- [ ] **Step 6: RuboCop**

```bash
bundle exec rubocop lib/apartment/tenant.rb spec/unit/tenant_spec.rb
```
Expected: no offenses. (If `reload_schema_cache!` trips `Metrics/MethodLength` or `Metrics/AbcSize`, the class already carries `# rubocop:disable Metrics/ModuleLength`/`ClassLength`; do NOT add a new disable unless RuboCop actually flags the method — if it does, add the minimal targeted `# rubocop:disable`/`# rubocop:enable` around the method matching the offense name reported.)

- [ ] **Step 7: Commit**

```bash
git add lib/apartment/tenant.rb spec/unit/tenant_spec.rb
git commit -m "Feat(v4): Apartment::Tenant.reload_schema_cache! recovery helper

Manual, current-process helper that clears the schema cache on warm tenant
pools (and the default pool) so the next query re-reflects the database.
Targets failure-class member 8's one apartment-specific case: DDL on a
pinned/shared table that N warm tenant pools have cached. Schema-cache only
(AR self-heals prepared statements); fetches the default pool via
with_default_tenant so the ConnectionHandling patch does not route it to a
tenant pool. Returns the count of pools cleared.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Documentation

**Files:**
- Modify: `docs/caching.md` (add `## Schema-cache recovery`)
- Modify: `docs/designs/fixture-pool-lifecycle.md` (member 8 status)
- Modify: `docs/designs/v4-beta-readiness.md` (W2 status)

**Interfaces:**
- Consumes: the shipped `Apartment::Tenant.reload_schema_cache!(tenant = nil)` API and the Task 1 fix.
- Produces: consumer-facing guidance (no code consumed by other tasks).

- [ ] **Step 1: Add the caching-doc section**

Append to `docs/caching.md` a new section (place it after the existing content, as a top-level `##`):

```markdown
## Schema-cache recovery

In v4, each tenant has its own connection pool and therefore its own schema
cache, so one tenant's DDL cannot corrupt another tenant's cache. After a
migration, the only staleness is the ordinary Rails "warm worker holds the old
schema until reload" — cured by your deploy restart. The one apartment-specific
case is DDL on a **pinned/shared (public-schema) table**: every warm tenant pool
that cached that table now holds stale metadata.

For that case (or manual DDL in a console), clear the cache in the current
process:

```ruby
Apartment::Tenant.reload_schema_cache!          # all warm tenant pools + default pool
Apartment::Tenant.reload_schema_cache!("acme")  # only that tenant's warm pools
```

It clears each pool's schema reflection; the next query re-reflects the
database. Returns the count of pools cleared.

**Limits — read before relying on it:**

- **Current process only.** It cannot reach other workers (web/Sidekiq). After
  fleet-wide DDL, a rolling restart remains the cure; this helper is for the
  process you call it from (console, a post-migrate maintenance script).
- **Schema reflection only, not prepared statements.** On PostgreSQL,
  ActiveRecord self-heals stale prepared statements (`cached plan must not
  change result type` → retry). On MySQL there is no equivalent auto-retry, so
  restart is more load-bearing there.
- **Does not reset model column caches.** A model class that already loaded its
  columns keeps them until `YourModel.reset_column_information` or a restart.
  This helper clears the *pool* cache, not `ActiveRecord::Base` model state.
- **Not a barrier.** An in-flight request may still use metadata it already
  read. Call it during a maintenance window / low-traffic moment, the same way
  Rails clears the schema cache after `db:migrate`.

Backward-compatible (additive) migrations rarely need this at all: old code does
not reference the new column, so a stale cache is inert until the next restart.
```

- [ ] **Step 2: Update the member-8 status in fixture-pool-lifecycle.md**

In `docs/designs/fixture-pool-lifecycle.md`, update the member-8 row of the failure-class table and its surrounding prose to reflect the shipped reactive recovery. Change the member 8 table row's Status cell from `Suspected` to `Reactive recovery shipped` and append to its Mechanism cell:

```markdown
v4's pool-per-tenant gives each tenant its own schema cache (no cross-tenant drift) and AR self-heals PG prepared statements; the residual shared/pinned-table-DDL amplifier is handled by the manual `Apartment::Tenant.reload_schema_cache!` recovery helper (current-process). Cross-process proactive invalidation stays deferred (transport seam). See `docs/designs/v4-schema-cache-recovery.md`.
```

(Leave members 7 and 9 unchanged.)

- [ ] **Step 3: Update W2 status in v4-beta-readiness.md**

In `docs/designs/v4-beta-readiness.md`, update the **W2** row in the Track A table. Replace its row with:

```markdown
- **W2 — Member 8, schema-cache / prepared-statement drift after tenant DDL** (shipped). Brainstorm showed v4's pool-per-tenant already isolates schema caches per pool and AR self-heals prepared statements, collapsing the long-pole scope. Shipped: the manual `Apartment::Tenant.reload_schema_cache!` recovery helper for the pinned/shared-table-DDL amplifier, plus a fix for the latent `schema_cache_per_tenant` load path. Design: `docs/designs/v4-schema-cache-recovery.md`.
```

Also update the **Critical path & sequencing** section: remove member 8 (W2) as an internal long pole, leaving the adopter `:reading` rollout (W6) as the remaining beta-date bound. Change the sentence beginning "Beta date is bounded below by `max(member-8 design+impl, adopter ...)`" to:

```markdown
**Beta date is bounded below by the adopter `:reading`-separated rollout green (W6)** now that member 8 (W2) is shipped. Everything else fits inside that envelope.
```

- [ ] **Step 4: Verify the docs render (links + no stray placeholders)**

```bash
grep -n "reload_schema_cache!" docs/caching.md docs/designs/fixture-pool-lifecycle.md docs/designs/v4-beta-readiness.md
grep -nE "TBD|TODO|FIXME|XXX" docs/caching.md docs/designs/v4-schema-cache-recovery.md || echo "no placeholders"
```
Expected: the helper name appears in all three docs; no placeholder markers.

- [ ] **Step 5: Commit**

```bash
git add docs/caching.md docs/designs/fixture-pool-lifecycle.md docs/designs/v4-beta-readiness.md
git commit -m "Docs(v4): schema-cache recovery helper + member-8 status

Document Apartment::Tenant.reload_schema_cache! in docs/caching.md (usage +
current-process/prepared-statement/model-reset/barrier limits + deploy-restart
and MySQL guidance). Mark failure-class member 8's reactive half shipped in
fixture-pool-lifecycle.md and W2 shipped in v4-beta-readiness.md, leaving the
adopter :reading rollout as the remaining beta-date bound.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Cross-version verification (before opening the PR)

- [ ] **Step 1: Touched specs across the Rails matrix**

```bash
bundle exec appraisal install   # first time only
bundle exec appraisal rails-7.2-sqlite3 rspec spec/unit/patches/connection_handling_spec.rb spec/unit/tenant_spec.rb
bundle exec appraisal rails-8.1-sqlite3 rspec spec/unit/patches/connection_handling_spec.rb spec/unit/tenant_spec.rb
```
Expected: green on both (the `SchemaReflection` / `schema_reflection=` / `clear!` API is stable across 7.2/8.0/8.1).

- [ ] **Step 2: Full unit suite under sqlite3, fixed seed**

```bash
bundle exec appraisal rails-8.1-sqlite3 rspec spec/unit/ --seed 19801
```
Expected: 0 failures. (Use a DB-bearing appraisal with a fixed seed — the bare `rspec spec/unit/` skips the real-AR specs, which is how a prior order-dependent leak slipped past local verification.)

---

## Self-Review

**1. Spec coverage** — every design requirement maps to a task:
- Helper API (`reload_schema_cache!(tenant = nil)`, warm pools + default pool, schema-cache only, count return) → Task 2.
- Default-pool inclusion catch (PoolManager doesn't track it) → Task 2 Step 1 (test) + Step 3 (`with_default_tenant` fetch).
- `clear!` repopulates from DB, not the dump file → relied on (verified against AR source in the design); helper tests assert the clear-contract, not Rails internals.
- Prepared statements omitted; model-cache + current-process + MySQL limits documented → Task 3.
- Bundled `schema_cache_per_tenant` load! fix → Task 1.
- Member-8 / W2 status updates → Task 3.

**2. Placeholder scan** — every code/doc step shows complete content; every run step shows the exact command and expected PASS/FAIL. No TBDs.

**3. Type consistency** — `reload_schema_cache!(tenant = nil)` is defined in Task 2 Step 3, tested under the same name/arity in Step 1, and documented identically in Task 3. `pool.schema_cache.clear!`, `Apartment.pool_manager.each_pair`, `with_default_tenant { }`, and `pool.schema_reflection =` match their verified ActiveRecord / apartment signatures.

**4. Scope** — one feature branch, three tasks (fix, helper, docs), one PR; no new dependency, no new public error class, no cross-process machinery.
