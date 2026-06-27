# Reading-Role Test Support (`:reading` multi-handler)

Status: shipped (role axis). Unblocks the fixture-pool-lifecycle workstream's "Eventually #7"
(multi-handler / `:reading` variant of the integration spec) and any future
`:reading`-role-gated coverage.

## TLDR

The v4 connection patch already keys pools by `"#{tenant}:#{role}"` and inherits
base config from the current role's default pool — so `:reading` routing works
today; the only gap is that no test ever registers a `:reading` default pool to
exercise it. We close that gap the lightweight way: register a `:reading`-role
default pool on `ActiveRecord::Base`'s ConnectionHandler **pointing at the same
physical database** (the proven `setup_connects_to!` pattern, minus the username
override), then add a read-based `:reading` context to
`fixture_pool_lifecycle_spec.rb` proving the lifecycle invariant holds per handler.
This closes member 5's **role axis**. Two things it deliberately does NOT do —
both because Rails makes `:reading` read-only and apartment never connection-shares
tenant pools: write *through* `:reading`, or make a `:reading` read see a `:writing`
in-test write. The latter is a real gap, recorded as failure-class member 10;
`fixture_pin_visibility_spec.rb` stays `:writing`-only. No real streaming replica,
no CI provisioning, no per-engine special-casing — a real replica would test
replication behavior the gem does not own and is irrelevant to the per-handler
lifecycle goal.

## Findings layer (verified against source)

- **Routing already handles `:reading`.** `Apartment::Patches::ConnectionHandling#connection_pool`
  (`lib/apartment/patches/connection_handling.rb`) computes
  `role = ActiveRecord::Base.current_role` and `pool_key = "#{tenant}:#{role}"`,
  establishes the tenant pool with `role: role`, and resolves its base config via
  `base = super` — which returns *the current role's* default pool. The sole
  prerequisite for `:reading` to flow through end-to-end is a `:reading` default
  pool registered on `AR::Base`.
- **The lightweight pattern already ships in-tree.** `RbacHelper.setup_connects_to!`
  (`spec/integration/v4/support/rbac_helper.rb`) registers a *second role*
  (`:db_manager`) on AR's ConnectionHandler against the **same database, different
  username**, and `role_aware_connection_spec.rb` already proves separate
  `tenant:role` pools, distinct pool keys, and base-config inheritance. `:reading`
  is a near-identical one-role delta.
- **#7's real surface is the integration helper, not the dummy app.** The #7 spec
  (`fixture_pool_lifecycle_spec.rb`) drives `FixtureLifecycleGuardHost` (real Rails
  fixture machinery) over the programmatic `V4IntegrationHelper`. It never boots
  the dummy app. Only `request_lifecycle_spec` and `live_streaming_spec` use the
  dummy app and its PG-only `database.yml`. The fixture-pool-lifecycle doc's
  "deferred until the dummy app gains read replicas" phrasing therefore names the
  wrong surface; this work corrects it.
- **The risk is per-handler, not per-engine.** Failure-class member 5:
  "`connection_pool_list` semantics differ in multi-DB / multi-role setups; the
  invariant must hold per handler, not globally." The fixture-pool spec is already
  PG-only (`:schema` strategy; `pin_connection!` semantics crispest there), so the
  cross-engine matrix is not in play for this spec.

## Goal and non-goals

**Goal:** exercise v4's multi-handler / `:reading`-role behavior in the test
suite, so the fixture-pool-lifecycle invariant ("pool lifecycle changes during
fixture-transaction ownership are a violation") is shown to hold *per handler* —
across both the `:writing` and `:reading` roles — closing #7's role axis and
unblocking other `:reading`-gated coverage. The coverage lands in
`fixture_pool_lifecycle_spec.rb` (lifecycle per handler). `fixture_pin_visibility_spec.rb`
stays `:writing`-only — read-visibility through `:reading` is not coherently
testable (see "Out of scope" below).

**Scope precision — the role axis, not the multi-DB or visibility axes.** Member 5
names "Non-`:writing` roles / replicas". This work closes the **role axis of the
lifecycle invariant** — that AR's transactional-fixture machinery pins/guards/rebuilds
a `:reading` tenant pool *per handler* the same way it does `:writing`. It does
**not** close the **multi-physical-DB axis** (a `:reading` role on a separate
database via `connects_to`) or **cross-role read visibility** (recorded as member 10);
see Deferred. On close, mark member 5's role axis closed (not the whole row), add
member 10 for the visibility gap, and correct the `fixture-pool-lifecycle.md`
"Eventually #7" entry, whose "deferred until the dummy app gains read replicas"
phrasing names the wrong surface.

**Why the role axis is the real risk (verified against AR 8.0/8.1 source).**
`setup_transactional_fixtures` snapshots and pins only
`connection_handler.connection_pool_list(:writing)` at setup — `:reading` pools
are *not* in the initial snapshot. Every `:reading` (and lazily-created) pool is
enrolled solely through the `!connection.active_record` subscriber, which
`retrieve_connection_pool`s by the *current* role. That asymmetry — `:writing`
pinned eagerly, `:reading` pinned only via the lazy subscriber — is exactly what
member 5's "must hold per handler, not globally" warns about, and is what these
specs prove holds. (The `fixture-pool-lifecycle.md` claim that the snapshot uses
`connection_pool_list(:all)` is inaccurate and is corrected as part of this work.)

**Non-goals:**

- Real streaming replication (PG physical replica, MySQL replication). Tests
  behavior the gem does not own; SQLite cannot replicate; heavy, fragile CI.
- A distinct least-privilege read-only database user. Production-shaped, but
  couples replica tests to RBAC's `CREATEROLE`-gated provisioning and the
  `:reading` role's *username* is not what #7 is testing.
- Dummy app `database.yml` 3-tier restructure / `connects_to` in
  `ApplicationRecord`. No current dummy-app spec needs `:reading`.

## Architecture

### Mechanism — same-DB second role

Register a `:reading` default pool on `AR::Base`'s ConnectionHandler with the same
configuration hash as the default (`:writing`) connection — same host, database,
and username. Once registered:

```ruby
ActiveRecord::Base.connected_to(role: :reading) do
  Apartment::Tenant.switch(tenant) do
    # current_role == :reading
    # pool_key == "#{tenant}:reading"
    # base config inherited from the :reading default pool via `super`
  end
end
```

This is structurally identical to how `role_aware_connection_spec.rb` already
drives `:db_manager`. Same-DB means there is nothing engine-specific to provision
— it is a second pool config over the same connection parameters.

### Helper — `V4IntegrationHelper.register_reading_role!`

A small, RBAC-free addition to `V4IntegrationHelper` (`spec/integration/v4/support.rb`),
sited next to `establish_default_connection!`:

```ruby
# Register a :reading-role default pool on AR::Base's ConnectionHandler,
# pointing at the same physical database as the default (:writing) connection.
# Mirrors RbacHelper.setup_connects_to! without a username override, and
# deliberately carries no RBAC role-provisioning dependency.
def register_reading_role!(base_config)
  db_config = ActiveRecord::DatabaseConfigurations::HashConfig.new(
    'test', 'primary_reading', base_config.transform_keys(&:to_s)
  )
  ActiveRecord::Base.connection_handler.establish_connection(
    db_config, owner_name: ActiveRecord::Base, role: :reading
  )
end
```

It lives in `V4IntegrationHelper`, **not** `RbacHelper`, so the fixture-pool spec
does not inherit RBAC's `CREATEROLE`-gated skip. The "register a role's default
pool" line is open-coded identically in `setup_connects_to!`; factor out a shared
private helper only if it reads cleanly — no speculative refactor of working RBAC
code.

The `:integration` around hook in `support.rb` swaps the ConnectionHandler per
example, so `register_reading_role!` must be called in a `before(:each)` (the same
constraint `setup_connects_to!` documents), after `establish_default_connection!`.

### Spec coverage — read-based `:reading` examples

**Reads, not writes — Rails forbids writing through `:reading`.** Verified against
source: `connection_handling.rb` (`with_role_and_shard`) hard-forces
`prevent_writes = true` whenever `role == ActiveRecord.reading_role`, and
`while_preventing_writes(false)` can't escape it (it re-enters `connected_to(role:
current_role)`, which re-forces it). Apps never write through `:reading`; they
write `:writing` and read `:reading`. So the `:reading` examples **materialize the
per-tenant pool with a READ** (`Widget.count`), then exercise the same lifecycle
invariant the `:writing` examples already do. The `:writing` examples keep their
write-based form unchanged.

In `fixture_pool_lifecycle_spec.rb`, add a `context 'under the :reading role'`
running these read-based examples (the `:writing` examples stay as they are — the
operations differ by role, so a single role-parametrized shared group would have
to branch read-vs-write and is not worth the indirection):

1. **Guard fires under `:reading`.** A read materializes (and the subscriber pins)
   a `"#{tenant}:reading"` pool; `reset_tenant_pools!` mid-tx then trips
   `Apartment::FixtureLifecycleViolation` (failure-class members 3 + 5).
2. **Violation message names the `:reading` pool.** Contract lock that the guard
   reports `"#{tenant}:reading"` and the `use_transactional_tests = false` opt-out.
3. **Pool identity under `:reading`.** With the test-env guard bypassed, a mid-tx
   reset discards the pinned `:reading` pool and the rebuilt pool has fresh object
   identity.

Plus one genuinely new assertion member 5 calls for:

4. **Both roles materialized as distinct, independently-pinned pools.** Write under
   `:writing`, read under `:reading` (the only direction Rails allows), then assert
   the two pools are **distinct objects** (`writing_pool != reading_pool`) and that
   **both are pinned** (`PoolReaper#pool_pinned?` true for each) — the per-handler
   proof. Pool identity + pinning are the load-bearing evidence, not row counts:
   same physical DB means a count is not independent evidence (panel review flagged
   a count-only assertion as degenerate). The `:writing` rows still roll back at
   teardown as a secondary sanity check.

The `before` block gains a `register_reading_role!(config)` call so the **default
shard** has a `:reading` `pool_config`. Why this matters, traced through AR's
`setup_shared_connection_pool` (verified against source): it walks each shard and
rewrites every non-writing role's `pool_config` to that shard's *writing* config.
For the default shard, `primary_reading` is validly swapped onto `primary_writing`
(the normal replica-fixtures path — non-nil, no raise). Apartment's tenant pools
live on *distinct* shards (`apartment_<t>:reading`), where the writing config is
`nil`; a naive swap there would `set_pool_config(:reading, shard, nil)` and raise
`ArgumentError`. `Apartment::TestFixtures` avoids that two ways — `reset_tenant_pools!`
clears tenant pools before the first `super`, and the `@apartment_fixtures_cleaned`
guard skips `super` on subscriber re-entry — so a lazily-created tenant `:reading`
pool is pinned directly by the subscriber and is **never** collapsed onto the
writing connection. That is the mechanism the both-roles example proves; it is
unit-covered in `test_fixtures_spec.rb` and now exercised under the real lifecycle.

### Out of scope — `fixture_pin_visibility_spec.rb` and read visibility

The plan originally folded a `:reading` parametrization into
`fixture_pin_visibility_spec.rb` (does a lazily-created pool's writes stay visible
on re-entry?). **Dropped as incoherent for `:reading`**, for two verified reasons:
writes can't go *through* `:reading` (above), and a tenant `:reading` pool does not
*see* the `:writing` pool's uncommitted in-test writes — probe: 3 rows written under
`:writing`, count under `:reading` = 0. The two roles are distinct pools = distinct
connections = distinct transactions on the same physical DB, and apartment never
connection-shares tenant pools (AR collapses only same-shard pools; tenant pools sit
on per-`tenant:role` shards). The visibility spec therefore stays `:writing`-only.

This is a real gap, not just a test limitation: a real primary/replica app on
transactional tests *expects* reads to see in-test writes (the purpose of
`setup_shared_connection_pool`), and apartment does not arrange it for tenant pools.
Recorded as failure-class **member 10** in `fixture-pool-lifecycle.md`; not fixed
here.

## Error handling and edge cases

- **`setup_shared_connection_pool` ArgumentError.** AR's unpatched
  `setup_shared_connection_pool` raises `ArgumentError (pool_config ... nil)` when
  a tenant pool exists under `:reading` only. `Apartment::TestFixtures`
  (`lib/apartment/test_fixtures.rb`) already guards this by resetting tenant pools
  before `super`; `test_fixtures_spec.rb` locks it at the unit level. Registering
  a `:reading` default pool gives the machinery a valid `pool_config` for the role
  regardless.
- **ConnectionHandler swap timing.** `register_reading_role!` registers on the
  *current* handler; it must run inside the per-example `before` (after the
  `:integration` around hook installs the fresh handler), never in
  `before(:context)`. Mirrors the documented `setup_connects_to!` constraint.
- **Role leakage across examples.** The around hook discards the handler (and its
  `:reading` pool) at teardown, so no explicit `:reading` teardown is required —
  same lifecycle as the RBAC pools.

## Testing

- Engine: PostgreSQL only, inherited from the existing
  `fixture_pool_lifecycle_spec.rb` `:schema` gate. Same-DB role registration needs
  no MySQL/SQLite provisioning, so no per-engine branching is added.
- Rails matrix: 7.2 / 8.0 / 8.1, via the existing appraisals (no matrix change).
- Verification: run
  `DATABASE_ENGINE=postgresql bundle exec appraisal rails-8.1-postgresql rspec spec/integration/v4/fixture_pool_lifecycle_spec.rb`
  green across the `:reading` context, plus the integration-level
  `reading_role_routing_spec.rb` that `register_reading_role!` registers a
  retrievable `:reading` pool and routes a switch to a `tenant:reading` pool.

## Deferred (recorded, not silently omitted)

- **Multi-physical-DB axis of member 5.** This work closes the role axis (a
  `:reading` role on the *same* database). The separate-database axis — a
  `:reading` role whose `pool_config` carries a different `database` key, the
  `connects_to database: { writing:, reading: }` production shape — is not
  exercised. Cheapest faithful approximation when needed: register `:reading`
  against a **second database name on the same PG instance** (no streaming
  replication), which additionally exercises the `base = super` config-inheritance
  path with a divergent `database` key. Tracked as the residual half of member 5,
  not built now (no adopter-reported need; adds `CREATE DATABASE` + schema
  duplication to test setup).
- **Cross-role read visibility under fixtures (member 10).** Making a tenant
  `:reading` pool see the `:writing` pool's in-test writes — what a real
  primary/replica app on transactional tests expects (the purpose of AR's
  `setup_shared_connection_pool`). Apartment doesn't arrange it for tenant pools;
  reads through `:reading` see `count 0` of `:writing`'s uncommitted writes
  (verified). Recorded as failure-class member 10; needs its own design (it would
  mean connection-sharing tenant pools across roles during fixtures).
- **Dummy app `:reading` wiring.** `database.yml` 3-tier + `connects_to` in
  `ApplicationRecord`, for `request_lifecycle` / `live_streaming` to exercise
  `:reading`. No current need.
- **Distinct read-only username / real streaming replica.** See non-goals. A real
  replica is read-only, so it cannot host the `Widget.create!` the rollback
  assertions require — same-DB is the *correct* minimal reproduction, not a
  compromise.

## Cross-references

- `lib/apartment/patches/connection_handling.rb` — `tenant:role` pool keying;
  `base = super` role-aware base-config inheritance.
- `spec/integration/v4/support/rbac_helper.rb` — `setup_connects_to!`, the
  same-DB second-role pattern this work mirrors.
- `spec/integration/v4/role_aware_connection_spec.rb` — existing proof that
  per-role tenant pools resolve with distinct keys and inherited config.
- `spec/integration/v4/fixture_pool_lifecycle_spec.rb` — the #7 integration spec
  being parametrized.
- `spec/integration/v4/fixture_pin_visibility_spec.rb` — the visibility sibling
  (deferred `:reading` companion).
- `lib/apartment/test_fixtures.rb` + `spec/unit/test_fixtures_spec.rb` — the
  `setup_shared_connection_pool` `:reading`-only sharp edge and its guard.
- `docs/designs/fixture-pool-lifecycle.md` — failure-class members 4 and 5,
  "Eventually #7"; the "dummy app gains read replicas" phrasing this work corrects.
- `docs/designs/apartment-v4.md` — the pool-per-`tenant:role` connection model.
- `docs/designs/v4-phase5.2-rbac-integration-tests.md` — RBAC role provisioning
  this work deliberately does *not* depend on.

## Origin

The fixture-pool-lifecycle workstream closed members 1–4 and deferred the
multi-handler / `:reading` variant (member 5, "Eventually #7") "until the dummy
app gains read replicas." Investigation showed the gate names the wrong surface:
#7 runs over the programmatic integration helper, the `:reading` route already
works at the patch level, and the same-DB second-role pattern already ships for
`:db_manager`. The lightweight approach therefore unblocks #7 directly with no
replication infrastructure.
