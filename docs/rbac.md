# RBAC: one DDL role, adopter-owned privilege policy

Apartment guarantees which database role executes tenant DDL. It issues no `GRANT` of its own.

Design rationale: [`designs/v4-rbac-contract.md`](designs/v4-rbac-contract.md).

## The rule

> Every statement **Apartment itself** issues against a tenant — from the Migrator, the create path, or the drop path — runs on `ddl_role`, except seeding. If your privilege model is scoped to the role that creates objects, and PostgreSQL's `ALTER DEFAULT PRIVILEGES` is exactly that, then it is scoped to `ddl_role`.

Seeding is outside the wrap because rows carry no ownership, and because seeds should be written by an identity resembling the runtime one.

Drop is inside it. `DROP SCHEMA` requires ownership and the container is owned by `ddl_role`, so a writing role generally cannot drop what the gem created. Only the engine call is wrapped; the pool removal and shard deregistration that follow are local bookkeeping.

```ruby
Apartment.configure do |c|
  c.ddl_role = :db_manager   # a Symbol naming an ActiveRecord connects_to role. nil = current role.
end
```

`ddl_role` is an ActiveRecord role, not a database user: declare it with `connects_to` and let `database.yml` carry the credential. If the role has no registration when the first tenant DDL runs, Apartment raises `Apartment::ConfigurationError` naming `ddl_role` and the symbol you gave it. The check is at first use rather than at boot, because under lazy loading no model has run `connects_to` when initializers finish, and "configured but not yet loaded" is indistinguishable from "missing" at that moment.

## The standard policy

For PostgreSQL schema-per-tenant:

```ruby
Apartment.configure do |c|
  c.ddl_role = :db_manager
  c.tenant_privilege_policy = Apartment::Privileges.standard(grant_to: 'app_user')
end
```

`grant_to` takes one role name or an Array of them, so separate runtime roles are one line:

```ruby
c.tenant_privilege_policy = Apartment::Privileges.standard(grant_to: %w[app_web app_worker])
```

An empty Array raises when the policy is built, rather than silently granting nothing. `include_functions:` defaults to true and controls only the `GRANT EXECUTE ON FUNCTIONS` default-privileges rule; PostgreSQL only.

What it issues, and where. Before the schema import: `GRANT USAGE ON SCHEMA`, plus three `ALTER DEFAULT PRIVILEGES FOR ROLE <ddl_role> … GRANT` rules covering tables, sequences and functions. After it: `GRANT … ON ALL TABLES` and `ON ALL SEQUENCES`, which cover the objects the import created. `FOR ROLE` is explicit rather than implied by whoever executed the statement, so the rule is correct by statement rather than by position.

For MySQL database-per-tenant the same one-liner works, and the whole policy is a single statement in the first phase: `GRANT SELECT, INSERT, UPDATE, DELETE ON <db>.* TO 'app_user'@'%'`. MySQL's database-scoped grant is pattern-based, so it already covers tables the import and later migrations create and there is nothing to do in the second phase.

`grant_to` values are **bare role names on MySQL too**, and every grant lands on `role@'%'`. A value carrying an `@` raises: `me@localhost` is itself a legal MySQL username, so splitting the value to find the host would sometimes grant to a different principal than you named. Granting to a specific host is a deliberate limit of the standard policy, and a custom policy is where it belongs.

**MySQL prerequisite.** `CREATE DATABASE` conveys no `GRANT OPTION`. A role that can create tenant databases is not necessarily one that can grant access to them, and a least-privilege deployment may separate the two on purpose. Two supported answers: give `ddl_role` `GRANT OPTION`, or have your policy open its own connection under a role that has it. The second is explicitly allowed — a policy may use `ctx.connection` or ignore it.

**No standard policy on two strategies.** PostgreSQL database-per-tenant needs cross-database ordering (`GRANT CONNECT` on the server, table grants inside the tenant database) that the helper does not implement, and SQLite has no role system at all. Configuring `Privileges.standard` on either raises `Apartment::ConfigurationError` rather than doing nothing; a silent no-op was the defect this design removes. Write a policy instead.

## Writing your own policy

A policy is any callable taking one argument. Apartment invokes it twice per create, once per phase, and ignores the return value.

```ruby
c.tenant_privilege_policy = lambda { |ctx|
  next unless ctx.before_schema_load?

  ctx.connection.execute("REVOKE ALL ON SCHEMA #{ctx.quoted_container} FROM PUBLIC")
}
```

Use `next`, not `return`. Both behave identically in a lambda, and `next` survives someone converting it to a proc.

The context carries five readers and three helpers.

`tenant` is the tenant name as Apartment knows it. `container_name` is the physical schema or database your statements must address, environmentified where the strategy does that; `quoted_container` is the same value quoted through the connection, and it is what belongs in interpolated SQL. Interpolating `tenant` instead silently targets the wrong object under any `environmentify_strategy`.

`db_role` is the resolved **database** role — the principal `ddl_role` maps to, resolved once per create. This is what lets a policy write `ALTER DEFAULT PRIVILEGES FOR ROLE …` and be correct regardless of where it runs. On PostgreSQL it is a role name and still needs identifier quoting; on MySQL it is `role@host`, which MySQL's own `GRANT` cannot take whole, so quote the halves separately as `'role'@'host'`. On SQLite it is nil.

`phase` is `:before_schema_load` or `:after_schema_load`, with `before_schema_load?` and `after_schema_load?` predicates.

`connection` is the ActiveRecord connection inside the `ddl_role` wrap. It is **valid for the duration of the invocation only**: do not retain it, and do not rely on session state surviving from one phase to the next — each phase gets its own context, and the gem guarantees neither object identity nor session continuity between them. Policies may also run concurrently with other work in the process, so a policy closing over mutable state of its own owns its own thread safety. Freezing the config does not freeze what a proc closed over.

Quote every identifier you interpolate. Tenant names have already passed `TenantNameValidator`, but role names have not and never do; `connection.quote_column_name` is the right quoter for a role, since `quote_table_name` splits on dots and a role named `svc.migrator` would come back as two identifiers.

The standard policy is itself just a callable, so composing is ordinary Ruby:

```ruby
standard = Apartment::Privileges.standard(grant_to: 'app_user')

c.tenant_privilege_policy = lambda { |ctx|
  standard.call(ctx)
  ctx.connection.execute("ALTER TABLE #{ctx.quoted_container}.widgets ENABLE ROW LEVEL SECURITY") if ctx.after_schema_load?
}
```

## Two phases, because position is policy

```
validate name
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

Which phase a statement belongs in is a property of your privilege model, not a detail.

A policy made only of `ALTER DEFAULT PRIVILEGES` rules works because the rules are recorded before the import, so imported tables inherit them. The same policy after the import leaves every imported table ungranted, with nothing raised until an ordinary query touches it. `REVOKE ALL … FROM PUBLIC`, container hardening, extensions and security labels also want the empty container.

Granting existing objects is the opposite case: `GRANT … ON ALL TABLES`, `ON ALL SEQUENCES`, and enabling row-level security on imported tables all need the objects to exist.

Both phases fire even when `schema_load_strategy` is nil, so a policy behaves the same whether or not you load a schema. `:after_schema_load` means "after the import step", including when that step did nothing.

Your `before`/`after` `:create` callbacks sit **outside** the `ddl_role` wrap and outside both phases, as they did before this contract existed.

The policy does **not** fire on `drop`. Drop runs its engine call on `ddl_role` for the ownership reason above, but tearing a container down needs no privilege policy.

**No create-time hook can cover tables that later migrations add.** Row-level security on those belongs in the migration that creates them. That is a property of migrations, not a gap here, and it is worth saying because a create-time hook is the first place people reach.

## When a policy fails

Provisioning is not atomic and cannot be made so: `CREATE SCHEMA` and `CREATE DATABASE` are not rollback-safe across engines, and MySQL DDL and `GRANT` are not transactional at all.

A raising policy aborts the create. Seeding does not run and the `:create` instrumentation event is not emitted.

The container survives. A failed create can leave a container behind, possibly with an imported schema and without privileges.

Retry is safe up to a point, and only up to it. Policies built from `GRANT` and `ALTER DEFAULT PRIVILEGES` are naturally idempotent and PostgreSQL container creation is already `CREATE SCHEMA IF NOT EXISTS`, so a failure in the `:before_schema_load` phase is safe to re-run. A failure *after* a partial schema import is not: re-running loads a schema over objects that already exist, and an existing container may have an unexpected owner. Recovery there is drop-and-recreate.

**A tenant must not become routable before its create succeeds.** If your provisioning row or `tenants_provider` publishes the tenant before `create` returns, the elevator will route live traffic into a tenant that fails on every write. That ordering is yours to control, and the failure looks like an outage rather than a misconfiguration.

## Migrating from `app_role`

`app_role` is removed with no shim. Its String form issued six statements on PostgreSQL schemas, one with different semantics on MySQL, and nothing at all on the other two adapters, so one key had four behaviours and no way to learn which you got.

```ruby
# before
c.app_role = 'app_user'

# after
c.ddl_role = :db_manager
c.tenant_privilege_policy = Apartment::Privileges.standard(grant_to: 'app_user')
```

The callable form took `(tenant, connection)` and now takes one context:

```ruby
# before
c.app_role = ->(tenant, conn) { conn.execute("GRANT USAGE ON SCHEMA #{tenant} TO reporting") }

# after
c.tenant_privilege_policy = lambda { |ctx|
  next unless ctx.before_schema_load?

  ctx.connection.execute("GRANT USAGE ON SCHEMA #{ctx.quoted_container} TO reporting")
}
```

`before_schema_load?` is where the old call site sat, so guarding on it preserves the old position. Two details of the rewrite are the point of the example: `quoted_container` rather than the raw tenant name, because the old signature handed over a logical name that is wrong under any `environmentify_strategy`; and `next` rather than `return`.
