# Reading-Role Test Support (`:reading` multi-handler)

Status: design. Unblocks the fixture-pool-lifecycle workstream's "Eventually #7"
(multi-handler / `:reading` variant of the integration spec) and any future
`:reading`-role-gated coverage.

## TLDR

The v4 connection patch already keys pools by `"#{tenant}:#{role}"` and inherits
base config from the current role's default pool — so `:reading` routing works
today; the only gap is that no test ever registers a `:reading` default pool to
exercise it. We close that gap the lightweight way: register a `:reading`-role
default pool on `ActiveRecord::Base`'s ConnectionHandler **pointing at the same
physical database** (the proven `setup_connects_to!` pattern, minus the username
override), then parametrize the role-sensitive examples in
`fixture_pool_lifecycle_spec.rb` (lifecycle/rollback) and
`fixture_pin_visibility_spec.rb` (read-visibility) across `:writing` and
`:reading`. No real streaming replica, no CI provisioning, no per-engine
special-casing. A real
replica would test replication behavior the gem does not own and is irrelevant
to #7's goal (pool object-identity and per-handler lifecycle, not replication
lag).

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
across both the `:writing` and `:reading` roles — closing #7 and unblocking other
`:reading`-gated coverage. Coverage spans both halves of failure-class member 5:
the lifecycle/rollback side (`fixture_pool_lifecycle_spec.rb`) and the
read-visibility side (`fixture_pin_visibility_spec.rb`). On close, correct the
`fixture-pool-lifecycle.md` "Eventually #7" entry, whose "deferred until the dummy
app gains read replicas" phrasing names the wrong surface.

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

### Spec coverage — parametrize role-sensitive examples

In `fixture_pool_lifecycle_spec.rb`, lift the role out of the hardcoded
`"#{tenant}:writing"` pool peeks and run the role-sensitive examples under both
`:writing` and `:reading` via a shared example group keyed on `role`. The
examples that carry per-handler signal:

1. **Guard fires under `:reading`.** A pinned `"#{tenant}:reading"` pool trips
   `Apartment::FixtureLifecycleViolation` when `reset_tenant_pools!` runs mid-tx
   (failure-class members 3 + 5).
2. **Lazy `:reading` enrollment + rollback (a′ under a second handler).** A
   `"#{tenant}:reading"` pool first materialized inside the example enrolls in the
   fixture transaction and its rows roll back at teardown (member 4, second
   handler).
3. **Pool identity under `:reading`.** With the test-env guard bypassed, a mid-tx
   reset discards the pinned `:reading` pool and the rebuilt pool has fresh object
   identity.

Plus one genuinely new assertion member 5 specifically calls for:

4. **Both roles pinned simultaneously.** With `"#{tenant}:writing"` *and*
   `"#{tenant}:reading"` pools pinned in the same example, the fixture lifecycle
   pins and rolls back **both** — the "invariant holds per handler, not globally"
   proof. This is the case neither the existing `:writing`-only spec nor a
   role-parametrized single-role run covers.

The `before` block gains a `register_reading_role!(config)` call so AR's fixture
machinery has a `:reading` `pool_config` (the `setup_shared_connection_pool`
sharp edge — AR raises `ArgumentError` when a tenant pool exists under `:reading`
without a `:writing` *or* `:reading` default pool_config — is already guarded by
`Apartment::TestFixtures` and unit-covered in `test_fixtures_spec.rb`; the
integration spec now exercises it under the real lifecycle).

### Spec coverage — visibility half under `:reading`

`fixture_pin_visibility_spec.rb` covers the read-visibility side of member 5: that
a lazily-created tenant pool, pinned late by the `!connection.active_record`
subscriber, still sees in-example writes on a later re-entry. Parametrize its
role-sensitive examples across `:writing` and `:reading` the same way, with a
`register_reading_role!(config)` call in its `before` block. The examples that
carry per-handler signal:

1. **Visibility on re-entry under `:reading`.** Rows written inside the example
   via a lazily-created `"#{tenant}:reading"` pool are visible to a later
   `Apartment::Tenant.each` pass on the same tenant.
2. **Visibility across `with_tenants` / `each` under `:reading`.** The same holds
   when a `with_tenants` override or bare `each` re-enters the tenant.
3. **Reaper detects the pinned `:reading` pool.** `PoolReaper#pool_pinned?`
   returns true for a freshly-pinned `"#{tenant}:reading"` pool (the private-ivar
   read triangulated against the real ConnectionPool, now under a second handler).

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
  green across the role parametrization, plus a unit-level check that
  `register_reading_role!` registers a retrievable `:reading` pool.

## Deferred (recorded, not silently omitted)

- **Dummy app `:reading` wiring.** `database.yml` 3-tier + `connects_to` in
  `ApplicationRecord`, for `request_lifecycle` / `live_streaming` to exercise
  `:reading`. No current need.
- **Distinct read-only username / real replica.** See non-goals.

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
