# The RBAC contract: one DDL role, adopter-owned privilege policy

**Status**: designed, not implemented. Supersedes the `migration_role` and `app_role` sections of [`v4-phase5-rbac-roles-schema-cache.md`](v4-phase5-rbac-roles-schema-cache.md), whose Key Invariant this replaces outright.

## Verdict

- **The gem owns role routing. The adopter owns privilege policy.** Apartment guarantees which database role executes tenant DDL; it stops issuing `GRANT` statements of its own.
- **`migration_role` becomes `ddl_role`.** The name was already wrong: the wrap covers container creation and schema import, not only migrations.
- **`app_role` is removed with no deprecation shim.** Its String form was a privilege policy the gem could not state correctly, and it silently did nothing on two of four adapters.
- **The engine-specific grant SQL survives as a public helper**, not as adapter behaviour. Deleting it would distribute PostgreSQL's `ALTER DEFAULT PRIVILEGES` trap to every adopter individually; demoting it keeps the knowledge and removes the implicitness.
- **Privilege policy is invoked twice, with a context object.** Position in the create sequence is policy-relevant, so a single call site cannot serve every privilege model.
- **The policy is told which database role it is running as.** Without that it would be correct only by accident of where it runs, which is the coupling that caused the bug this design exists to prevent.

## Why the current surface has to change

Two shipped bugs came out of the same root, and neither was a coding slip.

The first: PostgreSQL scopes `ALTER DEFAULT PRIVILEGES` (with no `FOR ROLE`) to the role that **executed** it. Tenant creation left that role to the caller while migrations always ran on `migration_role`, so the rule could be recorded under one role and the tables created under another. Every table a later migration added fell outside the rule, and nothing raised until an ordinary query touched it. Fixed by putting all tenant DDL inside one role wrap.

The second: creation switched into the container it had just built, which resolved a pool, which ran the pending-migration check against a tenant that had of course run no migration. Fixed by suppressing that check for the duration of a create.

Both were the same shape: the gem held one half of an invariant and left the other half to convention. The prior design doc named the invariant — "migration role = grantor role = schema owner" — and then called it *self-enforcing*, arguing that a create on some other role was still correct "because the grantor is whoever creates objects". That reasoning holds for one role in isolation and breaks across the pair.

Three further defects in the surface itself, none of which the bug fixes addressed:

**The String form of `app_role` is a policy pretending to be a convenience.** PostgreSQL schema-per-tenant issues six statements; MySQL issues one, with different semantics; PostgreSQL database-per-tenant and SQLite inherit a **silent no-op**. One config key, four behaviours, two of them nothing. An adopter reading the README has no way to learn which they got.

**The key is singular by construction.** One String, one grantee. An adopter with separate web, worker and reporting roles has to abandon the key entirely.

**`app_role` cannot express `FOR ROLE`.** The grantee is named in the config; the grantor is whoever happens to be connected. That is precisely the join the first bug turned on, and the config has no vocabulary for it.

## The contract

> Every statement **Apartment itself** issues against a tenant — from the Migrator, the create path, or the drop path — runs on `ddl_role`, except seeding. If your privilege model is scoped to the role that creates objects, and PostgreSQL's `ALTER DEFAULT PRIVILEGES` is exactly that, then it is scoped to `ddl_role`.

Two qualifications are load-bearing. "The Migrator, the create path, and the drop path" rather than "all DDL", because data-manipulating migrations run on `ddl_role` too and no DDL/DML filter exists. And "Apartment itself", because an adopter's privilege policy may deliberately open its own connection under another role — the MySQL section below depends on that being allowed.

Seeding is outside the wrap because rows carry no ownership, and because seeds should be written by an identity resembling the runtime one.

**Drop is included, and that is a behaviour change.** `drop_tenant` currently runs on whatever connection is ambient, which is asymmetric with a create that runs on `ddl_role`: `DROP SCHEMA` requires ownership or superuser, and the container is owned by `ddl_role`, so the writing role generally cannot drop what the gem just created. Only the engine call is wrapped — the pool removal and shard deregistration that follow it are local bookkeeping and stay outside. This is a behaviour change for anyone dropping tenants today on a role that happens to hold the privilege, and needs its own entry in the changelog.

## Dependency

The role wrap this design builds on is `Apartment::MigrationRole.wrap`, extracted from `Migrator.with_migration_role` so the adapters can reach it without depending on `Migrator`. That extraction is a separate in-flight change, not part of this design; implementation of this spec assumes it has landed, and the rename of `migration_role` to `ddl_role` touches it.

## Surface

```ruby
Apartment.configure do |c|
  c.ddl_role = :db_manager          # Symbol: an ActiveRecord connects_to role. nil = current role.

  # The common case: a prebuilt policy that owns its own phase mapping.
  c.tenant_privilege_policy = Apartment::Privileges.standard(grant_to: %w[app_web app_worker])

  # Or write your own. Invoked once per phase with a context; return value ignored.
  c.tenant_privilege_policy = lambda { |ctx|
    next unless ctx.before_schema_load?

    ctx.connection.execute("REVOKE ALL ON SCHEMA #{ctx.quoted_container} FROM PUBLIC")
  }
end
```

`ddl_role` replaces `migration_role`: same type, same validation, widened contract, honest name.

`tenant_privilege_policy` replaces `app_role`: callable only, no String form. Named for the house convention (`tenant_validator`, `tenant_not_found_handler`, `environmentify_strategy`) and because `tenant_privileges` reads like stored data rather than a hook.

### Removed

- `Apartment.config.app_role`, including the callable form's `(tenant, connection)` signature.
- `AbstractAdapter#grant_tenant_privileges` and `#grant_privileges`, and the overrides in `PostgresqlSchemaAdapter` and `Mysql2Adapter`.
- The inherited no-op on `PostgresqlDatabaseAdapter` and `Sqlite3Adapter`.

Nothing is deprecated in place. The gem is pre-GA under a soft-deprecation posture rather than a GA-binding freeze, and the removal breaks no known adopter: the one real adopter does not set `app_role`, having always maintained its own privilege code. A shim would preserve a defect.

## The context object

Positional arguments were the first draft and are wrong here. Four of them is already awkward, and every plausible extension — a grantee set, a new phase, a request principal — would break arity for every adopter at once.

A plain frozen class with keyword initialization and readers, **not** `Data.define` and not `Struct`.

`Data` is house style for value objects — `Migrator::Result`, `PoolObserver::Sample` — and this is not one. It carries a live connection: mutable, time-bound, and meaningless outside the invocation. `Data` would give it value equality, hashing, and positional decomposition as public semantics, none of which are sound over a connection. `Struct` is worse on both counts, being mutable and positionally biased.

The choice also makes the compatibility promise true rather than aspirational. **Additive-only, and precisely:** new fields arrive as keyword arguments with defaults, so a policy that reads attributes off a context Apartment handed it keeps working. Confirmed on Ruby 4.0.2, `Data` would not have delivered that — appending a member adds a required positional argument and a required keyword to `.new`, and `Data` responds to `deconstruct`, so an adopter destructuring positionally (`in [tenant, connection]`) or unit-testing with `Context.new(...)` would break on a minor release. Construction stays the gem's business; adopters receive contexts, they do not build them. A test factory is in scope if adopters ask for one.

Fields:

`tenant` is the tenant name as Apartment knows it.

`container_name` is the physical schema or database the statements must address — environmentified where the strategy does that. A policy interpolating `tenant` instead would silently target the wrong object under any `environmentify_strategy`, so the context carries both and the guide uses `container_name` throughout.

`quoted_container` is `container_name` quoted through the connection. Convenience with a purpose: it is the value every example needs, and an unquoted identifier in copied example code is the likeliest injection route into adopter policies.

`db_role` is the resolved **database** role name. This is the field that closes the structural gap: `ddl_role` is an ActiveRecord `connects_to` symbol whose actual database principal lives in `database.yml`, and the proc never had a way to see it. A policy can now write `ALTER DEFAULT PRIVILEGES FOR ROLE #{ctx.db_role} …` and be correct **by statement** rather than by position.

Resolution is adapter-delegated rather than one hardcoded query, because the token differs by engine. PostgreSQL's `SELECT current_user` yields a role name, which still needs identifier quoting before it goes into `FOR ROLE`; it is quoted with `quote_column_name`, since `quote_table_name` splits on dots and a role name may legally contain one. MySQL's `CURRENT_USER()` yields `role@host`, a token MySQL's own `GRANT` cannot take whole because it wants the halves quoted separately as `'role'@'host'` — so on MySQL the field carries the account for a policy's own use, and nothing in the gem interpolates it into a `GRANT`. SQLite has no role system: `db_role` is nil, and a policy needing it should not be configured there.

Resolved lazily — once per create, only when a policy is configured — so the extra round trip is not paid by adopters without one.

`phase` is `:before_schema_load` or `:after_schema_load`, with `before_schema_load?` and `after_schema_load?` predicates. Named for the lifecycle rather than for state: an earlier draft used `schema_loaded?`, which lies when `schema_load_strategy` is nil and no schema was ever loaded.

`connection` is the ActiveRecord connection inside the `ddl_role` wrap. **Valid for the duration of the invocation only.** A policy must not retain it, and must not rely on session state surviving from one phase to the next: each phase receives its own context, and the gem makes no object-identity or session-continuity guarantee between them. Policies may also run concurrently with other work in the process, so a policy capturing mutable state of its own is responsible for its own thread safety — freezing the config does not freeze what a proc closed over.

## Two phases, because position is policy

The hook is invoked at both points in the create sequence, as it will read once the in-flight pending-migration fix lands; the guide's copy of this diagram omits the suppression line, because that fix is on its own branch and the sequence below is the post-merge state:

```
validate name
suppress pending-migration check
  run :create callbacks
    ddl_role wrap
      create_tenant
      policy.call(context(phase: :before_schema_load))
      import_schema                    (when schema_load_strategy is set)
      policy.call(context(phase: :after_schema_load))
    leave wrap
    seed                               (when seed_after_create is set)
    instrument :create
```

The policy takes one argument. A fresh context is built per phase, carrying that phase; `phase` is not a second parameter. An earlier draft of this document wrote `tenant_privileges.(ctx, phase: :container_ready)`, which contradicts the documented arity and would raise.

The existing `:create` callback chain still wraps the whole operation, as it does today, which places adopter `before`/`after` callbacks **outside** the `ddl_role` wrap and outside both policy phases. That is unchanged behaviour, stated here because a reader looking at the sequence would otherwise have to guess.

The policy does **not** fire on `drop`. Drop runs its engine call on `ddl_role` for the ownership reason above, but tearing a container down needs no privilege policy.

A single post-import call site was the earlier plan, on the reasoning that `GRANT ON ALL TABLES` then covers imported tables while the default-privileges rule covers whatever migrations add later. That reasoning is sound for policies that grant existing objects explicitly, and **silently wrong for the ones that do not**. A policy consisting only of `ALTER DEFAULT PRIVILEGES` rules works today precisely because it runs before import: the rule is recorded, then imported tables inherit it. Move that same policy after import and every imported table is ungranted, with nothing raised — the app role fails only on schema-imported tables, which reads like data corruption rather than a grant gap.

Policies that need the empty container are not exotic:

- `REVOKE ALL ON SCHEMA … FROM PUBLIC` before any object exists.
- Container-level hardening, extensions, or security labels.
- Default-privileges-only models, as above.

Policies that need existing objects are equally ordinary: `GRANT … ON ALL TABLES`, `ON ALL SEQUENCES`, enabling row-level security on imported tables.

Both phases fire even when `schema_load_strategy` is nil, so a policy behaves the same whether or not the adopter loads a schema — `:after_schema_load` means "after the import step", including when that step did nothing. Adopters who care about one phase branch on the predicate; the cost of the second call is one invocation.

**What no create-time hook can do:** cover tables that later migrations add. Row-level security on those has to live in the migration that creates them. This is a property of migrations, not a gap in this design, and it is worth stating in the guide because adopters reach for a create-time hook first.

## The standard-grants helper

```ruby
Apartment::Privileges.standard(grant_to:, include_functions: true) # => a callable
```

**A policy factory, not a side-effecting call.** It returns an object responding to `#call(ctx)` that owns its own phase mapping, so the adopter never has to know which statements belong before the schema import and which after. That was the alternative's real cost: as an immediate `standard(ctx, ...)` the phase behaviour had to be specified in prose and re-derived by every adopter, and this document's own two examples disagreed about which phases to call it in.

The mapping it owns: the three `ALTER DEFAULT PRIVILEGES` rules run at `:before_schema_load`, so they cover imported tables and everything migrations add later; the `GRANT … ON ALL TABLES` and `ON ALL SEQUENCES` statements run at `:after_schema_load`, so they cover objects that exist by then. That split is exactly the knowledge an adopter should not have to reconstruct.

Composable, because it is just a callable:

```ruby
standard = Apartment::Privileges.standard(grant_to: 'app_user')
c.tenant_privilege_policy = lambda { |ctx|
  standard.call(ctx)
  ctx.connection.execute("...") if ctx.after_schema_load?
}
```

The granted capabilities are the same as the deleted adapter code's; the SQL is not identical, because `FOR ROLE` is now explicit rather than implied by the executing role.

`grant_to` accepts one role name or an Array of them. An empty Array raises at configure time rather than silently granting nothing. The values are bare role names, on MySQL as much as on PostgreSQL: MySQL grants land on `role@'%'`, and a value carrying an `@` raises rather than being split, because `me@localhost` is itself a legal MySQL username and guessing where the account divides would grant to a different principal than the caller named. Another host is what a custom policy is for.

`include_functions:` (rather than `functions:`, which reads like a list) controls only the `GRANT EXECUTE ON FUNCTIONS` default-privileges rule. It defaults to true, matching the deleted behaviour.

**Nothing runs unless the adopter configures it.** The ownership split holds: the gem ships the SQL as a library, not as implicit behaviour.

**Unsupported strategies raise `Apartment::ConfigurationError`.** `PostgresqlDatabaseAdapter` needs cross-database ordering (`GRANT CONNECT` on the server, table grants inside the tenant database) that the helper does not implement; SQLite has no role system. Not `NotImplementedError`: confirmed on Ruby 4.0.2 that it descends from `ScriptError`, not `StandardError`, so an adopter's `rescue StandardError` around `Tenant.create` would not catch it and the process would die on what is really a misconfiguration. The gem's existing use of `NotImplementedError` for abstract adapter methods is a different thing and stays. The silent no-op was the defect — a caller who explicitly asked for standard grants and got nothing had no way to find out.

The helper is what turns the acknowledged capability regression into one line of composition. Without it, "the adopter owns policy" means every adopter independently rediscovers that sequences need their own grant, that three separate default-privileges rules are required, and that `FOR ROLE` exists.

## Validation

**At `Apartment.configure`**, matching the existing conventions in `config.rb`:

- `ddl_role` is nil or a Symbol.
- `tenant_privilege_policy` is nil or responds to `call`.
- `Privileges.standard`'s `grant_to` is a non-empty String or Array of Strings.

**At first entry into the wrap**, not at boot: that `ddl_role` names a role ActiveRecord can resolve. `MigrationRole.wrap` rescues the pool-resolution failure and re-raises a `ConfigurationError` naming `ddl_role` and the symbol it was given.

A boot-time check was the earlier plan and is unsound. `activate!` runs inside `config.after_initialize`, and railties' finisher runs the eager-load initializer before the hook that fires `after_initialize`, with eager loading gated on `config.eager_load`. Under eager loading the model class bodies — and their `connects_to` calls — have executed, so the check would pass. Under lazy loading, which is development and most test setups, no model has loaded when `after_initialize` fires, so the check would fail on every boot. "Configured but not yet loaded" is indistinguishable from "missing" at that moment. Two further problems even where the timing works: `connects_to` registrations are per-class, so "does ActiveRecord know this role" is ambiguous about which class's registration counts, and there is no clean public API for the question.

**No warning when the policy is nil.** An earlier draft warned when `ddl_role` was set without a policy, on the grounds that the combination yields tenants the application cannot read. Cut: a nil policy legitimately means privileges are managed outside Apartment, or the runtime and DDL principals are the same, or the grants are pre-provisioned, or the topology is superuser. Warning on it would be the gem re-assuming ownership of privilege policy in the same breath as this document hands it away — and it would fire on the one adopter that already manages privileges correctly elsewhere.

## Failure semantics

Provisioning is **not atomic** and cannot be made so: `CREATE SCHEMA` and `CREATE DATABASE` are not rollback-safe across engines, and MySQL DDL and `GRANT` are not transactional at all.

The contract the guide must state:

**A raising policy aborts the create.** Seeding does not run, and the `:create` instrumentation event is not emitted.

**The container survives.** A failed create can leave a container, possibly with an imported schema, and without privileges. This is strictly more state than the old pre-import position left behind, which is the cost of two phases.

**Policies must be idempotent. `create` is re-runnable only up to a point, and the guide says where.** A policy built from `GRANT` and `ALTER DEFAULT PRIVILEGES` is naturally idempotent, and PostgreSQL container creation is already `CREATE SCHEMA IF NOT EXISTS`, so a failure in the `:before_schema_load` phase is safe to retry. A failure *after* a partial schema import is not: re-running loads a schema over objects that already exist, and an existing container may also have an unexpected owner. Recovery there is drop-and-recreate, not retry. An earlier draft claimed re-runnability flatly, which is true only of the first phase.

**A tenant must not become routable before its create succeeds.** If an adopter's provisioning row or `tenants_provider` publishes the tenant before `create` returns, the elevator will route live traffic into a tenant that fails on every write. That ordering is the adopter's, and the guide names it because the failure looks like an outage rather than a misconfiguration.

## Per-engine notes for the guide

**PostgreSQL schema-per-tenant.** The reference case. `ddl_role` owns the schema, so it can grant on it, and default privileges recorded under it cover what migrations add later.

**MySQL database-per-tenant.** `CREATE DATABASE` conveys no `GRANT OPTION`. A `ddl_role` that can create tenant databases is not necessarily one that can grant access to them, and a least-privilege deployment may deliberately separate the two. This is already true of the deleted built-in, where it looked automatic. Two supported answers: give `ddl_role` `GRANT OPTION`, or have the policy open its own connection under a role that has it. The second is explicitly supported — the proc may use `ctx.connection` or ignore it.

**PostgreSQL database-per-tenant.** No helper support; write the two-stage policy yourself.

**SQLite.** No roles. `tenant_privilege_policy` should be nil; the helper raises if configured.

## Migrating from `app_role`

String form:

```ruby
# before
c.app_role = 'app_user'

# after
c.ddl_role = :db_manager
c.tenant_privilege_policy = Apartment::Privileges.standard(grant_to: 'app_user')
```

Callable form:

```ruby
# before
c.app_role = ->(tenant, conn) { conn.execute("GRANT USAGE ON SCHEMA #{...} TO reporting") }

# after — one argument, two phases, an explicit container name
c.tenant_privilege_policy = lambda { |ctx|
  next unless ctx.before_schema_load?

  ctx.connection.execute("GRANT USAGE ON SCHEMA #{ctx.quoted_container} TO reporting")
}
```

An adopter relying on the old callable's position gets it back with `before_schema_load?`, which is where the old call site sat. Two details of the rewrite are the point of the example: `quoted_container` rather than the raw tenant name, because the old signature handed over a logical name that is wrong under any `environmentify_strategy`; and `next` rather than `return`, which behaves identically in a lambda and is the form that also survives someone converting it to a `proc`.

## Out of scope, deliberately

**Reconciliation across existing tenants.** Privileges are durable database state derived from mutable configuration. Rotate the credential behind `ddl_role` and every existing tenant's recorded default-privileges rule is scoped to a role that no longer runs migrations; the gap appears only when a future migration adds a table. A task that re-applies the configured policy across all tenants would make that a recoverable operation. It is not in this design because no adopter has hit it, and this repository has twice been burned naming public surface for a hypothetical. Deliberately not naming the method here either: naming it is how the last two cases started. Re-applying a policy across existing tenants is a loop over `tenant_names` calling something the implementation will already have, and it can be designed the day someone needs it.

**Per-principal database identity, including agent-on-behalf-of-user roles.** A role per *service* already works and this design improves it: pool keys are `"#{tenant}:#{role}"`, so a worker inside `connected_to(role: :app_worker)` gets its own pool per tenant, and `tenant_privilege_policy` grants to as many roles as the policy names. Plan for pools multiplying as tenants × runtime roles against `max_tenant_pools`.

A role per *end user* does not fit pool-per-tenant-per-role at any scale, and should not be attempted through it. The realistic mechanism is a request-scoped principal on a shared pool — `SET ROLE` per transaction, or row-level security keyed on a session variable — and that is a different layer with its own hazards: pool configs are immutable per pool, session state surviving a checkin is the leak class [`transaction-taint-detection.md`](transaction-taint-detection.md) exists to catch, and session-level state is what transaction-mode pooling breaks (see [`w4-pgbouncer-libpq-spike.md`](w4-pgbouncer-libpq-spike.md)). Nothing here forecloses it. The smallest thing that would validate the need is one adopter running one non-default runtime role end-to-end, which the `:reading` path already exercises.

## Testing

**Unit.** Config validation for both keys, including the empty `grant_to`. `Privileges.standard` statement-by-statement per engine, including that `FOR ROLE` names `ctx.db_role` and that each statement lands in the phase the mapping promises. `ConfigurationError` on the two unsupported strategies, and an explicit example that it is caught by `rescue StandardError` — the regression guard against someone reinstating `NotImplementedError`. Both phases fire, in order, with the right predicate true, with and without `schema_load_strategy`. A fresh context per phase, and `db_role` resolved once rather than per phase. `container_name` is the environmentified name, not the logical one, under each `environmentify_strategy`. A raising policy aborts the create, skips seeding, and emits no `:create` event. The `ConfigurationError` translation for an unresolvable `ddl_role`. Appending a field to the context does not break a policy that reads attributes.

**Integration, `:rbac` tag, real provisioned roles.** The existing lane already covers "migrations run as the DDL role" and "the app role can use migration-created tables". Added: a default-privileges-only policy at `:before_schema_load` covers schema-imported tables, which is the regression a single post-import call site would have introduced; a policy granting two runtime roles leaves both able to read; the `FOR ROLE` form survives a change of the executing role, which is the reconciliation gap made visible even though the fix is out of scope.

**Non-vacuity.** Per `spec/CLAUDE.md`, the two-phase and `FOR ROLE` examples must be seen failing with the relevant behaviour neutered before they count.

## Identifier quoting

`Privileges.standard` quotes every identifier it interpolates, through the connection, as the deleted adapter code did. Tenant names reaching it have already passed `TenantNameValidator`, but the helper does not rely on that: it is the gem's SQL and it quotes its own inputs.

Adopter policies that build their own SQL are responsible for their own quoting. The guide's examples all use `connection.quote_table_name`, because a copied example is the most likely source of an unquoted identifier in adopter code.
