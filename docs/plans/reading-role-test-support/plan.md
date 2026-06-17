# Reading-Role Test Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Exercise v4's multi-handler / `:reading`-role behavior in the integration suite by registering a same-database `:reading` default pool and parametrizing the two fixture-lifecycle specs across `:writing` and `:reading`, closing the fixture-pool-lifecycle "Eventually #7".

**Architecture:** A new RBAC-free helper, `V4IntegrationHelper.register_reading_role!`, registers a `:reading` default pool on `AR::Base`'s ConnectionHandler against the same physical database (mirroring `RbacHelper.setup_connects_to!` without a username override). The connection patch already keys pools `"#{tenant}:#{role}"` and inherits base config from `ActiveRecord::Base.current_role`, so wrapping a switch in `connected_to(role: :reading)` routes to a `"#{tenant}:reading"` pool. The role-sensitive examples in `fixture_pool_lifecycle_spec.rb` and `fixture_pin_visibility_spec.rb` move into role-parametrized shared example groups, run once per role, plus one new "both roles pinned simultaneously" assertion (the per-handler proof failure-class member 5 calls for).

**Tech Stack:** Ruby, RSpec, ActiveRecord (Rails 7.2 / 8.0 / 8.1), PostgreSQL (`:schema` strategy), appraisal.

## Global Constraints

- **v4 only.** `lib/apartment/` is all v4; v3 is deleted. No v3 references.
- **Open-source gem.** No references to CampusESP or any private repo/infra in code, docs, or commits.
- **PostgreSQL-only specs.** Both target specs are already PG-gated via the `:schema` strategy (`pin_connection!` semantics crispest there). No MySQL/SQLite branching is added; same-DB role registration needs no per-engine provisioning.
- **No new dependencies, no CI provisioning.** Same physical database, same username; no replication, no extra DB roles.
- **Rubocop before push.** Run `bundle exec rubocop` on every changed file (impl + specs) before any push. The suite disables `RSpec/ExampleLength`, `RSpec/MultipleExpectations`, `RSpec/NestedGroups`, `RSpec/ContextWording`; preserve the existing inline `# rubocop:disable RSpec/MultipleMemoizedHelpers` on the `RSpec.describe` lines.
- **Helper placement.** `register_reading_role!` lives in `V4IntegrationHelper` (`spec/integration/v4/support.rb`), NOT `RbacHelper` — the fixture specs must not inherit RBAC's `CREATEROLE`-gated skip.
- **Hook timing.** `register_reading_role!` must be called in `before(:each)`, after `establish_default_connection!`: the `:integration` around hook swaps the ConnectionHandler per example, so context-level registration would be discarded.

Reference design: `docs/designs/reading-role-test-support.md`.

---

### Task 1: `register_reading_role!` helper + end-to-end routing proof

Adds the helper and a small standalone spec proving `:reading` routing works (no fixtures, no RBAC) — the foundation the two fixture specs build on.

**Files:**
- Modify: `spec/integration/v4/support.rb` (add `register_reading_role!` to `module V4IntegrationHelper`)
- Create: `spec/integration/v4/reading_role_routing_spec.rb`

**Interfaces:**
- Produces: `V4IntegrationHelper.register_reading_role!(base_config)` — registers a `:reading` default pool on `ActiveRecord::Base.connection_handler` from `base_config` (a string- or symbol-keyed connection hash), via `establish_connection(db_config, owner_name: ActiveRecord::Base, role: :reading)`. Returns the established pool. Used by Tasks 2 and 3.

- [ ] **Step 1: Write the failing spec**

Create `spec/integration/v4/reading_role_routing_spec.rb`:

```ruby
# frozen_string_literal: true

require 'spec_helper'
require_relative 'support'

# Proves the :reading-role test seam end to end without fixtures or RBAC:
# register_reading_role! makes connected_to(role: :reading) route a tenant
# switch to a "#{tenant}:reading" pool whose base config is inherited from the
# :reading default pool. The same-physical-DB second-role pattern that unblocks
# the fixture-pool-lifecycle :reading variants (docs/designs/reading-role-test-support.md).
RSpec.describe('v4 :reading-role routing seam', :integration,
               skip: (V4_INTEGRATION_AVAILABLE && V4IntegrationHelper.postgresql? ? false : 'requires PostgreSQL')) do
  include V4IntegrationHelper

  let(:tenant) { "reading_seam_#{SecureRandom.hex(4)}" }

  before do
    V4IntegrationHelper.ensure_test_database!
    config = V4IntegrationHelper.establish_default_connection!
    V4IntegrationHelper.register_reading_role!(config)

    Apartment.configure do |c|
      c.tenant_strategy = :schema
      c.tenants_provider = -> { [tenant] }
      c.default_tenant = 'public'
      c.check_pending_migrations = false
    end
    Apartment.adapter = V4IntegrationHelper.build_adapter(config)
    Apartment.activate!
    Apartment.adapter.create(tenant)
  end

  after do
    V4IntegrationHelper.cleanup_tenants!([tenant], Apartment.adapter)
    Apartment.clear_config
    Apartment::Current.reset
  end

  it 'registers a retrievable :reading default pool on AR::Base' do
    pool = ActiveRecord::Base.connection_handler.retrieve_connection_pool(
      'ActiveRecord::Base', role: :reading
    )
    expect(pool).not_to(be_nil)
  end

  it 'routes a switch under connected_to(role: :reading) to a "tenant:reading" pool' do
    ActiveRecord::Base.connected_to(role: :reading) do
      Apartment::Tenant.switch(tenant) { ActiveRecord::Base.connection }
    end

    expect(Apartment.pool_manager.stats[:tenants]).to(include("#{tenant}:reading"))
    expect(Apartment.pool_manager.stats[:tenants]).not_to(include("#{tenant}:writing"))
  end
end
```

- [ ] **Step 2: Run the spec to verify it fails**

Run: `DATABASE_ENGINE=postgresql bundle exec appraisal rails-8.1-postgresql rspec spec/integration/v4/reading_role_routing_spec.rb`
Expected: FAIL with `NoMethodError: undefined method 'register_reading_role!' for V4IntegrationHelper`.

- [ ] **Step 3: Add the helper**

In `spec/integration/v4/support.rb`, inside `module V4IntegrationHelper`, add the method immediately after `establish_default_connection!` (keep it next to the other connection-establishment helpers):

```ruby
  # Register a :reading-role default pool on AR::Base's ConnectionHandler,
  # pointing at the same physical database as the default (:writing) connection.
  # Mirrors RbacHelper.setup_connects_to! without a username override, and
  # carries no RBAC role-provisioning dependency. Returns the established pool.
  #
  # Call in before(:each), after establish_default_connection!: the :integration
  # around hook swaps the ConnectionHandler per example, discarding any
  # context-level registration.
  def register_reading_role!(base_config)
    db_config = ActiveRecord::DatabaseConfigurations::HashConfig.new(
      'test', 'primary_reading', base_config.transform_keys(&:to_s)
    )
    ActiveRecord::Base.connection_handler.establish_connection(
      db_config, owner_name: ActiveRecord::Base, role: :reading
    )
  end
```

- [ ] **Step 4: Run the spec to verify it passes**

Run: `DATABASE_ENGINE=postgresql bundle exec appraisal rails-8.1-postgresql rspec spec/integration/v4/reading_role_routing_spec.rb`
Expected: PASS (2 examples, 0 failures).

- [ ] **Step 5: Rubocop the changed files**

Run: `bundle exec rubocop spec/integration/v4/support.rb spec/integration/v4/reading_role_routing_spec.rb`
Expected: no offenses (fix any that appear before committing).

- [ ] **Step 6: Commit**

```bash
git add spec/integration/v4/support.rb spec/integration/v4/reading_role_routing_spec.rb
git commit -m "Test(v4): register_reading_role! helper + :reading routing seam"
```

---

### Task 2: Parametrize `fixture_pool_lifecycle_spec.rb` across roles

Move the role-sensitive examples (guard-fires, fresh-identity, a′ rollback) into a role-parametrized shared example group; run for `:writing` and `:reading`; add the both-roles-pinned per-handler proof. Leave the role-agnostic examples (message text, negative/bootstrap, `with_tenants`/`Current`) running once under `:writing`.

**Files:**
- Modify: `spec/integration/v4/fixture_pool_lifecycle_spec.rb`

**Interfaces:**
- Consumes: `V4IntegrationHelper.register_reading_role!` (Task 1).

- [ ] **Step 1: Register the :reading role in the before block**

In the `before do` block, immediately after the line
`config = V4IntegrationHelper.establish_default_connection!(tmp_dir: tmp_dir)`, add:

```ruby
    V4IntegrationHelper.register_reading_role!(config)
```

- [ ] **Step 2: Extract role-sensitive examples into a shared group**

Define a shared example group at the top of the file, after the `require` lines and before the `RSpec.describe`. It contains the parametrized versions of the existing examples 1, 4, and 5 plus the new both-roles example. Each `run_example` body is wrapped in `connected_to(role:)`, and every pool peek uses `pool_key` (or an explicit role string for the both-roles case):

```ruby
RSpec.shared_examples('fixture pool lifecycle guards under a role') do |role|
  let(:pool_key) { "#{write_tenant}:#{role}" }

  it "raises Apartment::FixtureLifecycleViolation when a #{role} tenant pool is pinned by fixtures" do
    widget_class

    expect do
      FixtureLifecycleGuardHost.new.run_example do
        ActiveRecord::Base.connected_to(role: role) do
          Apartment::Tenant.switch(write_tenant) { Widget.create! }
          expect(Apartment.pool_manager.peek(pool_key)).not_to(be_nil)

          Apartment.reset_tenant_pools!
        end
      end
    end.to(raise_error(Apartment::FixtureLifecycleViolation))
  end

  it "violation message names the offending #{role} tenant pool and the use_transactional_tests opt-out" do
    widget_class

    message = nil
    begin
      FixtureLifecycleGuardHost.new.run_example do
        ActiveRecord::Base.connected_to(role: role) do
          Apartment::Tenant.switch(write_tenant) { Widget.create! }
          Apartment.reset_tenant_pools!
        end
      end
    rescue Apartment::FixtureLifecycleViolation => e
      message = e.message
    end

    expect(message).not_to(be_nil)
    expect(message).to(include(pool_key))
    expect(message).to(include('transactional fixtures'))
    expect(message).to(include('use_transactional_tests = false'))
    expect(message).to(include('docs/testing.md'))
  end

  it "mid-tx reset discards the pinned #{role} pool: the recreated pool has fresh object identity" do
    widget_class

    FixtureLifecycleGuardHost.new.run_example do
      ActiveRecord::Base.connected_to(role: role) do
        Apartment::Tenant.switch(write_tenant) { Widget.create! }
        pool_before = Apartment.pool_manager.peek(pool_key)

        allow(Rails).to(receive(:env).and_return(ActiveSupport::StringInquirer.new('development')))
        Apartment.reset_tenant_pools!

        Apartment::Tenant.switch(write_tenant) { Widget.create! }
        pool_after = Apartment.pool_manager.peek(pool_key)

        expect(pool_after).not_to(be(pool_before))
        expect(pool_after.object_id).not_to(eq(pool_before.object_id))
      end
    end
  end

  it "rolls back rows written via lazy #{role} pool creation in the non-reset path (a' tiebreaker)" do
    widget_class

    FixtureLifecycleGuardHost.new.run_example do
      ActiveRecord::Base.connected_to(role: role) do
        Apartment::Tenant.switch(write_tenant) { Widget.create! }
      end
    end

    post_rollback_count = nil
    ActiveRecord::Base.connected_to(role: role) do
      Apartment::Tenant.switch(write_tenant) { post_rollback_count = Widget.count }
    end

    expect(post_rollback_count).to(eq(0))
  end
end
```

- [ ] **Step 3: Delete the now-duplicated inline examples and include the shared group per role**

Inside the `RSpec.describe(...)` body, DELETE the three original inline examples whose titles are:
- `'raises Apartment::FixtureLifecycleViolation when a tenant pool is pinned by fixtures'`
- `'mid-tx reset discards the pinned pool: the recreated pool has fresh object identity'`
- `'rolls back rows written via lazy pool creation in the non-reset path (a′ tiebreaker)'`

DELETE the original inline `'violation message names the offending tenant pool and
points at the use_transactional_tests opt-out'` example too — it is now covered
(parametrized) by the shared group above, which asserts the message names the
role-specific `pool_key` under both `:writing` and `:reading`.

KEEP the two remaining role-agnostic examples unchanged:
- `'is allowed outside fixture-transaction ownership (negative case)'`
- `'preserves a with_tenants override across fixture setup (reset_tenant_pools! leaves Current intact)'`

In place of the deleted examples, add the role loop and the new both-roles example:

```ruby
  %i[writing reading].each do |role|
    context "under the :#{role} role" do
      include_examples('fixture pool lifecycle guards under a role', role)
    end
  end

  it 'pins both :writing and :reading tenant pools as distinct objects and rolls both back' do
    # The per-handler proof (failure-class member 5, role axis): with pinned
    # pools under BOTH roles in one example, the fixture lifecycle must enroll
    # both. Same physical DB, so a post-teardown count is NOT independent
    # evidence (both reads hit the same rows). The load-bearing assertions are
    # the mid-example ones: the two pools are distinct objects and both pinned.
    # The post-teardown counts are a secondary sanity check.
    widget_class
    counts = {}
    reaper = Apartment::PoolReaper.new(
      pool_manager: Apartment.pool_manager, interval: 60, idle_timeout: 60
    )

    FixtureLifecycleGuardHost.new.run_example do
      ActiveRecord::Base.connected_to(role: :writing) do
        Apartment::Tenant.switch(write_tenant) { Widget.create! }
      end
      ActiveRecord::Base.connected_to(role: :reading) do
        Apartment::Tenant.switch(write_tenant) { Widget.create! }
      end

      writing_pool = Apartment.pool_manager.peek("#{write_tenant}:writing")
      reading_pool = Apartment.pool_manager.peek("#{write_tenant}:reading")

      # Distinct pool objects per role (not collapsed onto one connection).
      expect(writing_pool).not_to(be_nil)
      expect(reading_pool).not_to(be_nil)
      expect(reading_pool).not_to(be(writing_pool))

      # Both enrolled in the fixture transaction (pinned), per handler.
      expect(reaper.send(:pool_pinned?, writing_pool)).to(be(true))
      expect(reaper.send(:pool_pinned?, reading_pool)).to(be(true))
    end

    # Secondary: rows written via both roles are gone after teardown rollback.
    Apartment::Tenant.switch(write_tenant) { counts[:writing] = Widget.count }
    ActiveRecord::Base.connected_to(role: :reading) do
      Apartment::Tenant.switch(write_tenant) { counts[:reading] = Widget.count }
    end

    expect(counts[:writing]).to(eq(0))
    expect(counts[:reading]).to(eq(0))
  end
```

- [ ] **Step 4: Update the header comment block**

The describe-block header comment lists "Six examples"; update its count and add the role-parametrization and both-roles lines so the comment matches reality. Replace the `# Six examples:` enumeration intro with:

```ruby
# Role-agnostic examples (run once, under :writing): the negative/bootstrap
# case and the with_tenants/Current-survival case.
# Role-sensitive examples (run under both :writing and :reading via the
# 'fixture pool lifecycle guards under a role' shared group): the guard-fires
# case, the violation-message contract lock, the fresh-object-identity case,
# and the (a') lazy-rollback tiebreaker.
# Plus one both-roles-pinned example: the per-handler proof (failure-class
# member 5, role axis) that the fixture lifecycle enrolls distinct tenant pools
# under both roles simultaneously (distinct objects, both pinned).
```

- [ ] **Step 5: Run the spec to verify it passes**

Run: `DATABASE_ENGINE=postgresql bundle exec appraisal rails-8.1-postgresql rspec spec/integration/v4/fixture_pool_lifecycle_spec.rb`
Expected: PASS. Example count rises from 6 to 11 (2 role-agnostic + 4×2 role-parametrized + 1 both-roles). 0 failures.

- [ ] **Step 6: Run across the Rails matrix**

Run: `DATABASE_ENGINE=postgresql bundle exec appraisal rails-7.2-postgresql rspec spec/integration/v4/fixture_pool_lifecycle_spec.rb` and the same for `rails-8.0-postgresql`.
Expected: PASS on both.

- [ ] **Step 7: Rubocop**

Run: `bundle exec rubocop spec/integration/v4/fixture_pool_lifecycle_spec.rb`
Expected: no offenses. (The `# rubocop:disable RSpec/MultipleMemoizedHelpers` on the `RSpec.describe` line stays.)

- [ ] **Step 8: Commit**

```bash
git add spec/integration/v4/fixture_pool_lifecycle_spec.rb
git commit -m "Test(v4): parametrize fixture pool lifecycle guards over :writing/:reading

Closes the rollback/lifecycle half of fixture-pool-lifecycle member 5: the
guard-fires, fresh-identity, and (a') tiebreaker examples now run under both
roles, plus a both-roles-pinned example proving one fixture transaction covers
tenant pools across handlers."
```

---

### Task 3: Parametrize `fixture_pin_visibility_spec.rb` across roles

Same pattern for the read-visibility half of member 5: lazily-created `:reading` tenant pools, pinned late by the `!connection.active_record` subscriber, must still show in-example writes on re-entry.

**Files:**
- Modify: `spec/integration/v4/fixture_pin_visibility_spec.rb`

**Interfaces:**
- Consumes: `V4IntegrationHelper.register_reading_role!` (Task 1).

- [ ] **Step 1: Register the :reading role in the before block**

In the `before do` block, immediately after
`config = V4IntegrationHelper.establish_default_connection!(tmp_dir: tmp_dir)`, add:

```ruby
    V4IntegrationHelper.register_reading_role!(config)
```

- [ ] **Step 2: Extract the role-sensitive visibility examples into a shared group**

Add this shared example group after the `require` lines and before the `RSpec.describe`. It is the role-parametrized form of existing examples 1, 2, 3, and 4 (`FixtureLifecycleHost` is the host class defined inside the describe block; the shared group references it the same way the inline examples do):

```ruby
RSpec.shared_examples('fixture pin visibility under a role') do |role|
  it "sees rows written inside the example when a later pass re-enters the #{role} tenant" do
    widget_class
    counts = {}

    FixtureLifecycleHost.new.run_example do
      ActiveRecord::Base.connected_to(role: role) do
        Apartment::Tenant.switch(write_tenant) do
          5.times { Widget.create! }
          Apartment::Tenant.each { |tenant| counts[tenant] = Widget.count }
        end
      end
    end

    expect(counts[write_tenant]).to(eq(5))
  end

  it "sees in-example #{role} writes when a with_tenants override wraps the local switch" do
    widget_class
    counts = {}

    FixtureLifecycleHost.new.run_example do
      ActiveRecord::Base.connected_to(role: role) do
        Apartment::Tenant.with_tenants(*tenants) do
          Apartment::Tenant.switch(write_tenant) do
            5.times { Widget.create! }
            Apartment::Tenant.each { |tenant| counts[tenant] = Widget.count }
          end
        end
      end
    end

    expect(counts[write_tenant]).to(eq(5))
  end

  it "sees in-example #{role} writes when each re-enters the tenant from a with_tenants override" do
    widget_class
    counts = {}

    FixtureLifecycleHost.new.run_example do
      ActiveRecord::Base.connected_to(role: role) do
        Apartment::Tenant.switch(write_tenant) { 5.times { Widget.create! } }

        Apartment::Tenant.with_tenants(*tenants) do
          Apartment::Tenant.each { |tenant| counts[tenant] = Widget.count }
        end
      end
    end

    expect(counts[write_tenant]).to(eq(5))
  end

  it "pins the lazily-created #{role} tenant pool detectably for PoolReaper" do
    widget_class
    reaper = Apartment::PoolReaper.new(
      pool_manager: Apartment.pool_manager, interval: 60, idle_timeout: 60
    )
    pinned_mid_example = nil

    FixtureLifecycleHost.new.run_example do
      ActiveRecord::Base.connected_to(role: role) do
        Apartment::Tenant.switch(write_tenant) do
          Widget.create!
          pool = Apartment.pool_manager.peek("#{write_tenant}:#{role}")
          pinned_mid_example = reaper.send(:pool_pinned?, pool)
        end
      end
    end

    expect(pinned_mid_example).to(be(true))
  end
end
```

- [ ] **Step 3: Delete the now-duplicated inline examples and include the shared group per role**

Inside the `RSpec.describe(...)` body, DELETE the four original inline examples whose titles are:
- `'sees rows written inside the example when a later pass re-enters the tenant'`
- `'sees in-example writes when a with_tenants override wraps the local switch'`
- `'sees in-example writes when each re-enters the tenant from a with_tenants override'`
- `'pins the lazily-created tenant pool detectably for PoolReaper'`

KEEP the last example unchanged (role-agnostic reaper in-use guard):
- `'PoolReaper skips a tenant pool with an open transaction even when unpinned'`

In place of the deleted examples, add the role loop:

```ruby
  %i[writing reading].each do |role|
    context "under the :#{role} role" do
      include_examples('fixture pin visibility under a role', role)
    end
  end
```

- [ ] **Step 4: Update the header comment block**

Append a sentence to the describe-block header comment noting role coverage:

```ruby
# The visibility examples run under both :writing and :reading (the
# 'fixture pin visibility under a role' shared group), covering the
# read-visibility half of fixture-pool-lifecycle failure-class member 5:
# lazily-created tenant pools pin and stay visible per handler.
```

- [ ] **Step 5: Run the spec to verify it passes**

Run: `DATABASE_ENGINE=postgresql bundle exec appraisal rails-8.1-postgresql rspec spec/integration/v4/fixture_pin_visibility_spec.rb`
Expected: PASS. Example count rises from 5 to 9 (4×2 role-parametrized + 1 role-agnostic). 0 failures.

- [ ] **Step 6: Run across the Rails matrix**

Run the same command for `rails-7.2-postgresql` and `rails-8.0-postgresql`.
Expected: PASS on both.

- [ ] **Step 7: Rubocop**

Run: `bundle exec rubocop spec/integration/v4/fixture_pin_visibility_spec.rb`
Expected: no offenses.

- [ ] **Step 8: Commit**

```bash
git add spec/integration/v4/fixture_pin_visibility_spec.rb
git commit -m "Test(v4): parametrize fixture pin visibility over :writing/:reading

Closes the read-visibility half of fixture-pool-lifecycle member 5: lazily
created tenant pools pin late and stay visible on re-entry under both roles."
```

---

### Task 4: Correct the fixture-pool-lifecycle "Eventually #7" entry

The #7 gate names the wrong surface ("the dummy app gains read replicas"). Correct it to reflect that #7 is closed via the integration helper's `:reading` role.

**Files:**
- Modify: `docs/designs/fixture-pool-lifecycle.md`

- [ ] **Step 1: Rewrite the "Eventually" #7 entry**

Replace the current item 7 under the `## Eventually (>1mo, deferred)` heading:

```markdown
7. **Multi-handler / multi-role variants of the integration spec**. Parametrize over `:writing` and `:reading` roles once the dummy app supports replicas. Deferred until reading replicas are exercised in the main matrix.
```

with (closes #7's role axis; move it out of "Eventually" by recording it as done):

```markdown
7. **Multi-handler / multi-role variants of the integration spec** — *role axis closed*. Both `fixture_pool_lifecycle_spec.rb` (rollback/lifecycle) and `fixture_pin_visibility_spec.rb` (read-visibility) now run their role-sensitive examples under both `:writing` and `:reading`, plus a both-roles-pinned example proving the fixture lifecycle enrolls distinct, independently-pinned tenant pools per handler (failure-class member 5, role axis). The earlier "deferred until the dummy app gains read replicas" framing named the wrong surface: the integration spec runs over the programmatic `V4IntegrationHelper`, not the dummy app, and a same-database `:reading` default pool (`register_reading_role!`) exercises multi-handler routing without any replication. The multi-physical-DB axis (a `:reading` role on a separate database) remains a tracked residual. Design: `docs/designs/reading-role-test-support.md`.
```

- [ ] **Step 2: Update failure-class member 5 status (role axis only)**

In the `## Failure class members` table, change member 5's Status to
`Role axis closed; multi-DB axis open` — NOT a flat `Closed`. The role axis (a
`:reading` role on the same database) is proven; the multi-physical-DB axis (a
`:reading` role on a separate database via `connects_to`) is not. The row
currently reads:

```markdown
| 5 | Non-`:writing` roles / replicas | Suspected | `connection_pool_list` semantics differ in multi-DB / multi-role setups; the invariant must hold per handler, not globally. |
```

Replace with:

```markdown
| 5 | Non-`:writing` roles / replicas | Role axis closed; multi-DB axis open | Role axis: AR snapshots only `connection_pool_list(:writing)` at fixture setup, so `:reading` tenant pools enroll solely via the lazy `!connection.active_record` subscriber. The two fixture specs now run role-sensitive examples under both `:writing` and `:reading`, with a both-roles-pinned example asserting distinct, independently-pinned pool objects per handler. Multi-DB axis (a `:reading` role on a separate database) is tracked residual. See `docs/designs/reading-role-test-support.md`. |
```

- [ ] **Step 3: Update the prose pointer to #7**

In the paragraph after the failure-class table, the text reads "The next active piece of work is the multi-handler / `:reading` variant (Eventually #7), gated on the dummy app gaining replicas." Replace that sentence with:

```markdown
The multi-handler / `:reading` variant (Eventually #7) has its role axis closed via a same-database `:reading` default pool in the integration helper (see `docs/designs/reading-role-test-support.md`); the multi-physical-DB axis and failure-class members 7, 8, 9 remain tracked but out of scope this iteration.
```

- [ ] **Step 4: Correct the `connection_pool_list(:all)` claim in Detection primitives**

The `## Detection primitives` section asserts the fixture snapshot uses
`connection_pool_list(:all)`. Verified against ActiveRecord 8.0/8.1 source
(`active_record/test_fixtures.rb` `setup_transactional_fixtures`), the initial
snapshot is `connection_pool_list(:writing)` — `:reading` and lazily-created
pools enroll only via the `!connection.active_record` subscriber. The line
currently reads:

```markdown
- `ActiveRecord::Base.connection_handler.connection_pool_list(:all)` — snapshot consumed by fixture machinery. Read-only from Apartment's side; do not mutate.
```

Replace with:

```markdown
- `ActiveRecord::Base.connection_handler.connection_pool_list(:writing)` — the pools `setup_transactional_fixtures` snapshots and pins *eagerly*. `:reading` (and any lazily-created) pools are NOT in this snapshot; they enroll only through the `!connection.active_record` subscriber, which pins by the current role. This `:writing`-eager / `:reading`-lazy asymmetry is the per-handler risk failure-class member 5 names. Read-only from Apartment's side; do not mutate.
```

- [ ] **Step 5: Verify the edits**

Run: `grep -n "closed\|axis\|reading-role-test-support\|connection_pool_list(:writing)" docs/designs/fixture-pool-lifecycle.md`
Expected: matches in the member-5 row, the #7 entry, the prose pointer, and the Detection-primitives line; no remaining "deferred until the dummy app gains read replicas" text and no remaining `connection_pool_list(:all)`.

- [ ] **Step 6: Commit**

```bash
git add docs/designs/fixture-pool-lifecycle.md
git commit -m "Docs(fixture-pool-lifecycle): close #7 role axis; fix snapshot primitive

Close failure-class member 5's role axis (multi-DB axis tracked residual) and
correct the Detection-primitives claim: AR snapshots connection_pool_list(:writing),
not (:all) — the :writing-eager / :reading-lazy asymmetry is the actual risk."
```

---

### Task 5: Full-suite verification before push

Confirm no regression across the integration suite and that all changed files are clean.

- [ ] **Step 1: Run the full PG integration suite**

Run: `DATABASE_ENGINE=postgresql bundle exec appraisal rails-8.1-postgresql rspec spec/integration/v4/`
Expected: PASS (0 failures). Confirms the new `:reading` default pool registration in the two fixture specs does not regress sibling specs.

- [ ] **Step 2: Run the unit suite**

Run: `bundle exec rspec spec/unit/`
Expected: PASS (0 failures). No production code changed, so this is a guard, not a target.

- [ ] **Step 3: Rubocop all changed files**

Run:
```bash
bundle exec rubocop spec/integration/v4/support.rb \
  spec/integration/v4/reading_role_routing_spec.rb \
  spec/integration/v4/fixture_pool_lifecycle_spec.rb \
  spec/integration/v4/fixture_pin_visibility_spec.rb \
  docs/designs/fixture-pool-lifecycle.md
```
Expected: no offenses (markdown is ignored by rubocop; the four ruby files must be clean).

- [ ] **Step 4: Push and open PR**

```bash
git push -u origin feat/reading-role-test-support
```
Open a PR to `main` (squash-merge). Title: `Test(v4): :reading-role multi-handler coverage (closes fixture-pool #7)`. Body summarizes the same-DB second-role approach and links `docs/designs/reading-role-test-support.md`.

---

## Self-Review

**Spec coverage** (against `docs/designs/reading-role-test-support.md`):
- Mechanism (same-DB `:reading` role) → Task 1 helper + Task 2/3 `before` registration. ✓
- Helper in `V4IntegrationHelper`, RBAC-free → Task 1. ✓
- `fixture_pool_lifecycle_spec` role parametrization (guard, message, identity, a′) + both-roles case → Task 2. ✓
- `fixture_pin_visibility_spec` role parametrization (visibility ×3, reaper pin) → Task 3. ✓
- Doc correction (member 5 role-axis status + #7 + prose + `connection_pool_list(:writing)` fix) → Task 4. ✓
- Panel-review revisions: both-roles example asserts distinct pool objects + both pinned (not count-only); member 5 closed for role axis only, multi-DB axis recorded residual; snapshot-primitive factual fix. ✓
- PG-only, no per-engine branching, no CI provisioning → constraints honored; specs stay PG-gated. ✓
- Rubocop before push → Task 1/2/3 per-file + Task 5 sweep. ✓

**Placeholder scan:** No TBD/TODO; every code step shows full code; commands have expected output. ✓

**Type consistency:** `register_reading_role!(base_config)` defined in Task 1, consumed verbatim in Tasks 2/3. Pool keys consistently `"#{tenant}:#{role}"`. `pool_key` let used uniformly within each shared group. ✓
