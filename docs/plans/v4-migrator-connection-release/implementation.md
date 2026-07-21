# Migrator per-tenant connection release — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Release each worker's leased connection after every tenant migration so finished migration pools stop jamming pool admission (`skip_evict` / `cap_unmet`).

**Architecture:** One targeted change in `Apartment::Migrator#migrate_tenant`: capture the tenant's `ConnectionPool` inside the `switch` block and, in the method's existing `ensure`, best-effort `release_connection` on it. Execution-context scoped, so it only releases the calling worker's own lease. Plus a dedicated integration spec and a version bump.

**Tech Stack:** Ruby, ActiveRecord (Rails 7.2–8.1), RSpec, Apartment v4 pool-per-tenant model.

**Design doc:** `docs/designs/v4-migrator-per-tenant-connection-release.md`

## Global Constraints

- **Targeted release only.** Use `pool.release_connection` on the captured tenant pool. Do NOT use `ActiveRecord::Base.connection_handler.clear_active_connections!(:all)` — its breadth would release a caller's other leases on the shared sequential / `migrate_one` paths.
- **Best-effort.** A release failure must be rescued and `warn`ed, never raised — it must not mask a migration error or corrupt the returned `Result`.
- **Do not touch `migrate_primary`.** It uses the app's default pool, which is eviction-protected and must not be released here.
- **No per-tenant pool teardown.** Do not add `remove`/`deregister_shard`/`evict_by_role` per tenant. The end-of-run `evict_migration_pools` stays as-is.
- **Rails version floor:** `release_connection` is public `ActiveRecord::ConnectionAdapters::ConnectionPool` API across the supported 7.2–8.1 matrix; no version guard needed.

---

### Task 1: Release the tenant connection in `migrate_tenant`

**Files:**
- Modify: `lib/apartment/migrator.rb` (`Apartment::Migrator#migrate_tenant`, currently lines 145–188)
- Create: `spec/integration/v4/migrator_connection_release_spec.rb`

**Interfaces:**
- Consumes: `Apartment::Migrator.new(threads:)#run`; `Apartment.pool_manager.peek(pool_key)` → `ActiveRecord::ConnectionAdapters::ConnectionPool`; pool key format `"#{tenant}:#{ActiveRecord::Base.current_role}"`.
- Produces: no new public API. `migrate_tenant` behavior: after it returns (success, skip, or failure), the tenant's pool has zero `in_use?` connections and zero open transactions attributable to the migrating worker.

- [ ] **Step 1: Write the failing test (success path)**

Create `spec/integration/v4/migrator_connection_release_spec.rb`. This mirrors the setup in `spec/integration/v4/migrator_integration_spec.rb` (no `migration_role`, no cap — so `evict_migration_pools` no-ops and pools survive for inspection).

```ruby
# frozen_string_literal: true

require 'spec_helper'
require_relative 'support'
require 'apartment/migrator'

# Regression coverage for docs/designs/v4-migrator-per-tenant-connection-release.md:
# migrate_tenant must release the worker's leased connection so finished pools
# are no longer in_use? (and therefore admission-evictable).
#
#   bundle exec appraisal rails-8.1-sqlite3 rspec spec/integration/v4/migrator_connection_release_spec.rb
RSpec.describe('v4 Migrator connection release', :integration) do
  before(:all) do
    skip('requires ActiveRecord + database gem') unless V4_INTEGRATION_AVAILABLE
  end

  include V4IntegrationHelper

  let(:tmp_dir) { Dir.mktmpdir('apartment_migrator_release') }
  let(:migrations_dir) { File.join(tmp_dir, 'migrate') }
  let(:test_tenants) { %w[release_test_a release_test_b release_test_c] }
  let(:original_migrations_paths) { ActiveRecord::Migrator.migrations_paths.dup }

  def write_test_migration(dir)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, '20240101000001_create_release_test_widgets.rb'), <<~RUBY)
      # frozen_string_literal: true
      class CreateReleaseTestWidgets < ActiveRecord::Migration[7.0]
        def change
          create_table(:release_test_widgets, force: true) do |t|
            t.string :name
          end
        end
      end
    RUBY
  end

  # Peek the pool AR created for a tenant under the current role, without
  # touching its idle timestamp.
  def tenant_pool(tenant)
    Apartment.pool_manager.peek("#{tenant}:#{ActiveRecord::Base.current_role}")
  end

  def busy_connections(pool)
    pool.connections.count { |c| c.in_use? }
  end

  def open_transactions(pool)
    pool.connections.sum { |c| c.respond_to?(:open_transactions) ? c.open_transactions : 0 }
  end

  before do
    write_test_migration(migrations_dir)
    ActiveRecord::Migrator.migrations_paths = [migrations_dir]

    V4IntegrationHelper.ensure_test_database! unless V4IntegrationHelper.sqlite?
    config = V4IntegrationHelper.establish_default_connection!(tmp_dir: tmp_dir)

    Apartment.configure do |c|
      c.tenant_strategy = V4IntegrationHelper.tenant_strategy
      c.tenants_provider = -> { test_tenants }
      c.default_tenant = V4IntegrationHelper.default_tenant
      c.check_pending_migrations = false
    end

    Apartment.adapter = V4IntegrationHelper.build_adapter(config)
    Apartment.activate!
    test_tenants.each { |t| Apartment.adapter.create(t) }
  end

  after do
    ActiveRecord::Migrator.migrations_paths = original_migrations_paths
    Apartment::Tenant.reset
    V4IntegrationHelper.cleanup_tenants!(test_tenants, Apartment.adapter)
    Apartment.clear_config
    Apartment::Current.reset
    if V4IntegrationHelper.sqlite?
      ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
      FileUtils.rm_rf(tmp_dir)
    end
  end

  it 'leaves no leased connection on any tenant pool after a successful run' do
    Apartment::Migrator.new(threads: 0).run

    test_tenants.each do |tenant|
      pool = tenant_pool(tenant)
      expect(pool).not_to(be_nil), "expected a pool for #{tenant}"
      expect(busy_connections(pool)).to(
        eq(0), "expected #{tenant} pool to have no leased connection after migrating"
      )
      expect(open_transactions(pool)).to(eq(0))
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it FAILS**

Run: `bundle exec appraisal rails-8.1-sqlite3 rspec spec/integration/v4/migrator_connection_release_spec.rb -e "no leased connection"`
Expected: FAIL — `busy_connections(pool)` is `1` (the migrating thread's lease is never checked in). If it unexpectedly PASSES, stop: the leak premise is wrong for this Rails version — reassess before implementing.

- [ ] **Step 3: Implement the release in `migrate_tenant`**

Edit `lib/apartment/migrator.rb`. Make exactly three changes to `migrate_tenant`:

(a) Add `tenant_pool = nil` immediately after `Apartment::Current.migrating = true` (method scope, so it is visible in the `ensure`):

```ruby
    def migrate_tenant(tenant) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      start = monotonic_now
      Apartment::Current.migrating = true
      tenant_pool = nil
```

(b) Capture the pool as the FIRST statement inside the `switch` block, and read `migration_context` off it (so the skip path is covered and we don't call `connection_pool` twice):

```ruby
      with_migration_role do
        Apartment::Tenant.switch(tenant) do
          tenant_pool = ActiveRecord::Base.connection_pool
          context = tenant_pool.migration_context
```

(c) Extend the existing `ensure` (currently just resets the `migrating` flag) with the best-effort release:

```ruby
    ensure
      Apartment::Current.migrating = false
      # Release THIS worker's lease on the tenant pool so the finished pool is no
      # longer in_use? and becomes admission-evictable. Targeted (not handler-wide
      # clear_active_connections!) so the shared sequential / migrate_one paths,
      # which run on a caller-owned execution context, do not release a caller's
      # other leases. Best-effort: a release failure must never mask a migration
      # error or the returned Result.
      # See docs/designs/v4-migrator-per-tenant-connection-release.md.
      begin
        tenant_pool&.release_connection
      rescue StandardError => release_error
        warn "[Apartment::Migrator] connection release failed: " \
             "#{release_error.class}: #{release_error.message}"
      end
    end
```

Leave `migrate_primary`, `run`, `run_parallel`, `run_sequential`, and `evict_migration_pools` unchanged.

- [ ] **Step 4: Run the success-path test to verify it PASSES**

Run: `bundle exec appraisal rails-8.1-sqlite3 rspec spec/integration/v4/migrator_connection_release_spec.rb -e "no leased connection"`
Expected: PASS.

- [ ] **Step 5: Add the failure-path and skip-path tests**

Append two more examples inside the same `describe` block in `spec/integration/v4/migrator_connection_release_spec.rb`.

Failure path — a raising migration must still release (and Rails must have rolled the transaction back, so `open_transactions == 0` too):

```ruby
  it 'releases the connection even when a tenant migration raises' do
    # Add a second migration that always raises, so migrate_tenant hits its rescue.
    File.write(File.join(migrations_dir, '20240101000002_boom.rb'), <<~RUBY)
      # frozen_string_literal: true
      class Boom < ActiveRecord::Migration[7.0]
        def change
          raise 'boom'
        end
      end
    RUBY

    run = Apartment::Migrator.new(threads: 0).run
    expect(run.failed).not_to(be_empty)

    test_tenants.each do |tenant|
      pool = tenant_pool(tenant)
      next if pool.nil?

      expect(busy_connections(pool)).to(eq(0))
      expect(open_transactions(pool)).to(eq(0))
    end
  end

  it 'releases cleanly on the skip path (already up to date)' do
    Apartment::Migrator.new(threads: 0).run          # bring all tenants current
    second = Apartment::Migrator.new(threads: 0).run  # everything :skipped now

    expect(second.results.reject { |r| r.tenant == Apartment.config.default_tenant })
      .to(all(have_attributes(status: :skipped)))

    test_tenants.each do |tenant|
      pool = tenant_pool(tenant)
      expect(busy_connections(pool)).to(eq(0)) if pool
    end
  end
```

- [ ] **Step 6: Run the full new spec file to verify all pass**

Run: `bundle exec appraisal rails-8.1-sqlite3 rspec spec/integration/v4/migrator_connection_release_spec.rb`
Expected: 3 examples, 0 failures.

- [ ] **Step 7: Rubocop on both changed files**

Run: `bundle exec rubocop lib/apartment/migrator.rb spec/integration/v4/migrator_connection_release_spec.rb`
Expected: no offenses. (If `migrate_tenant` trips `Metrics/MethodLength`/`AbcSize`, the existing `rubocop:disable` on its `def` line already covers it — do not add new disables without cause.)

- [ ] **Step 8: Commit**

```bash
git add lib/apartment/migrator.rb spec/integration/v4/migrator_connection_release_spec.rb
git commit -m "Fix(v4): Migrator releases each tenant's connection after migrating

migrate_tenant leased a connection per tenant (switch restores Current.tenant
but never checks the connection in), leaving finished migration pools in_use?
and non-evictable — the skip_evict/cap_unmet amplifier. Capture the tenant pool
inside the switch block and best-effort release_connection it in the ensure.
Targeted (not handler-wide) so the shared sequential/migrate_one paths don't
release a caller's other leases.

See docs/designs/v4-migrator-per-tenant-connection-release.md.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_014NsWCDm8xAb6EwHfCaniDp"
```

---

### Task 2: Guards — caller-connection safety + admission under a cap

**Files:**
- Modify: `spec/integration/v4/migrator_connection_release_spec.rb` (add the caller-held-connection safety example to the existing `describe`, then a `describe 'under a pool cap'` context)

**Interfaces:**
- Consumes: `Apartment::Migrator#migrate_tenant` (private — invoked via `.send(:migrate_tenant, name)` for the isolated safety test); `Apartment.configure { |c| c.max_tenant_pools = N }` (wires `PoolReaper` as the admission controller); `Apartment.pool_manager.stats[:tenants]`; `ActiveSupport::Notifications` event `cap_unmet.apartment`; the `tenant_pool` / `busy_connections` helpers from Task 1's spec file.
- Produces: (a) proof that the targeted release does NOT disturb a connection the caller holds on a *different* pool (the guard that fails if anyone swaps in `clear_active_connections!(:all)`); (b) proof that after release, sequential migration over more tenants than the cap does not emit `:cap_unmet` and keeps registered pools bounded by the cap — the deterministic stand-in for the production `skip_evict`/`cap_unmet` flood.

- [ ] **Step 1: Add the caller-connection safety test**

This is the design doc's fourth Testing scenario ("release does not disturb a caller-held connection"). Add it as an example in the **existing top-level `describe`** in `spec/integration/v4/migrator_connection_release_spec.rb` (it reuses the `tenant_pool` and `busy_connections` helpers already defined there). It leases tenant A's pool on the test thread, migrates a *different* tenant B via `migrate_tenant`, and asserts A's lease survived while B's was released. A handler-wide `clear_active_connections!(:all)` would release A too — so this example is the regression guard for the targeted-vs-`:all` decision.

```ruby
  it 'targeted release does not disturb a connection the caller holds on another pool' do
    # Caller leases tenant A's pool on this thread; switch does not check it in,
    # so the lease persists after the block (that is the bug this fix addresses).
    Apartment::Tenant.switch(test_tenants[0]) do
      ActiveRecord::Base.connection.execute('SELECT 1')
    end
    pool_a = tenant_pool(test_tenants[0])
    expect(busy_connections(pool_a)).to(eq(1)) # caller's lease established

    # Migrate a DIFFERENT tenant; its targeted release touches only tenant B's pool.
    Apartment::Migrator.new(threads: 0).send(:migrate_tenant, test_tenants[1])

    expect(busy_connections(pool_a)).to(eq(1)) # caller's lease on A untouched
    expect(busy_connections(tenant_pool(test_tenants[1]))).to(eq(0)) # B released
  end
```

- [ ] **Step 2: Write the cap test**

Add this context to `spec/integration/v4/migrator_connection_release_spec.rb`. It re-runs `Apartment.configure` with a cap (config is frozen after configure, so a fresh `configure` + `activate!` is required — see CLAUDE.md "Frozen config"). Uses sequential migration to avoid thread-timing flakiness; the background reaper's 300s idle timeout guarantees it does not interfere, so any eviction is admission-driven.

```ruby
  describe 'under a pool cap (admission)' do
    # default pool (protected) + cap of 2 tenant pools, migrating 3 tenants,
    # forces at least one admission eviction. With the connection released after
    # each tenant, the LRU tenant pool is not in_use? and evicts cleanly, so no
    # :cap_unmet fires. Without release it would (the production incident).
    before do
      Apartment.configure do |c|
        c.tenant_strategy = V4IntegrationHelper.tenant_strategy
        c.tenants_provider = -> { test_tenants }
        c.default_tenant = V4IntegrationHelper.default_tenant
        c.check_pending_migrations = false
        c.max_tenant_pools = 2
      end
      Apartment.activate!
    end

    it 'does not emit :cap_unmet and keeps registered pools within the cap' do
      cap_unmet = []
      sub = ActiveSupport::Notifications.subscribe('cap_unmet.apartment') do |*args|
        cap_unmet << args.last
      end

      Apartment::Migrator.new(threads: 0).run

      # Count only the test-tenant pools (keys "<tenant>:<role>"), excluding the
      # protected default pool and any reading-role pool, so the bound is robust.
      tenant_pool_count = Apartment.pool_manager.stats[:tenants].count do |key|
        test_tenants.any? { |t| key.to_s.start_with?("#{t}:") }
      end
      expect(cap_unmet).to(be_empty)
      expect(tenant_pool_count).to(be <= 2)
    ensure
      ActiveSupport::Notifications.unsubscribe(sub)
    end
  end
```

> Event name confirmed: `Apartment::Instrumentation.instrument(:cap_unmet, ...)` publishes `cap_unmet.apartment` (all Apartment events are `*.apartment`, per `lib/apartment/instrumentation.rb`). The `subscribe('cap_unmet.apartment')` string above is correct.

- [ ] **Step 3: Run both new tests**

Run: `bundle exec appraisal rails-8.1-sqlite3 rspec spec/integration/v4/migrator_connection_release_spec.rb -e "caller holds" -e "under a pool cap"`
Expected: PASS — caller's lease on A survives; no `:cap_unmet`; tenant pools ≤ 2.

Sanity check (proves both tests have teeth): temporarily change `tenant_pool&.release_connection` in `migrate_tenant` to `ActiveRecord::Base.connection_handler.clear_active_connections!(:all)` and re-run — the caller-connection test should FAIL (A's lease dropped to 0). Then comment the release out entirely and re-run — the cap test should FAIL with a non-empty `cap_unmet`. Restore the correct line before committing.

- [ ] **Step 4: Rubocop**

Run: `bundle exec rubocop spec/integration/v4/migrator_connection_release_spec.rb`
Expected: no offenses.

- [ ] **Step 5: Commit**

```bash
git add spec/integration/v4/migrator_connection_release_spec.rb
git commit -m "Test(v4): guard caller-connection safety and cap admission on release

Two guards for the release fix: (1) targeted release does not disturb a
connection the caller holds on another pool — the regression guard against
swapping in clear_active_connections!(:all); (2) deterministic stand-in for the
production skip_evict/cap_unmet flood — with a 2-pool cap and 3 tenants migrated
sequentially, admission evicts the released LRU tenant pool cleanly and no
:cap_unmet fires.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_014NsWCDm8xAb6EwHfCaniDp"
```

---

### Task 3: Version bump to 4.0.0.alpha10

**Files:**
- Modify: `lib/apartment/version.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `Apartment::VERSION == '4.0.0.alpha10'`.

- [ ] **Step 1: Bump the version**

Edit `lib/apartment/version.rb`:

```ruby
# frozen_string_literal: true

module Apartment
  VERSION = '4.0.0.alpha10'
end
```

- [ ] **Step 2: Verify the gem builds**

Run: `gem build ros-apartment.gemspec`
Expected: builds `ros-apartment-4.0.0.alpha10.gem` with no error. Remove the built artifact afterward: `rm -f ros-apartment-4.0.0.alpha10.gem`.

- [ ] **Step 3: Commit**

```bash
git add lib/apartment/version.rb
git commit -m "Bump version to 4.0.0.alpha10

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_014NsWCDm8xAb6EwHfCaniDp"
```

---

## Verification before PR

- [ ] Full new spec file green on SQLite: `bundle exec appraisal rails-8.1-sqlite3 rspec spec/integration/v4/migrator_connection_release_spec.rb`
- [ ] Existing migrator specs still green (no regression): `bundle exec appraisal rails-8.1-sqlite3 rspec spec/integration/v4/migrator_integration_spec.rb spec/unit/migrator_spec.rb`
- [ ] PostgreSQL pass (the incident engine): `DATABASE_ENGINE=postgresql bundle exec appraisal rails-8.1-postgresql rspec spec/integration/v4/migrator_connection_release_spec.rb`
- [ ] Rubocop clean on all changed files: `bundle exec rubocop lib/apartment/migrator.rb lib/apartment/version.rb spec/integration/v4/migrator_connection_release_spec.rb`
