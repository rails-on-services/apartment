# Out-of-band tenant DDL — the contract, and why no eviction helper ships

**Status**: designed 2026-07-13, from live-database evidence. Supersedes the W3 /
failure-class-member-9 narrative in [`v4-beta-readiness.md`](v4-beta-readiness.md)
and [`fixture-pool-lifecycle.md`](fixture-pool-lifecycle.md), both of which
described a failure that does not reproduce.

## Verdict

- **Out-of-band tenant DDL does not strand a warm pool.** Probed across five
  configurations on live PostgreSQL 18 and MySQL 8.4. The claimed mechanism — a
  "baked `search_path`" and "dead table OIDs" producing `PG::UndefinedTable` on the
  next switch — is refuted. `search_path` is a **name**, re-resolved by the server
  per query.
- **No tenant-scoped pool-eviction helper ships.** Nothing it would fix is broken.
  Adding one would freeze a no-op into the v4 public surface at the API freeze.
- **The real defect is a two-sided footgun**, and it has nothing to do with DDL:
  `Apartment.deregister_shard` and `PoolManager#remove_tenant` are each half of one
  operation, both reachable, and **either half alone is wrong**. Fixed here.
- **The supported answers already exist**: `Apartment::Tenant.reload_schema_cache!`
  for metadata drift, `Apartment.reset_tenant_pools!` to discard pools outright.
- **One case would justify eviction, and it is not DDL**: a tenant's *connection
  config* changing at runtime (remap to another database/host/shard, credential
  rotation). Deferred deliberately — see [Deferred: the remap case](#deferred-the-remap-case).

## Evidence

Every row below was measured, not reasoned. Probes drove real ActiveRecord against
real databases; the regression specs in
`spec/integration/v4/out_of_band_tenant_ddl_spec.rb` pin these behaviors so we learn
if Rails or the engines change them underneath us.

| Configuration | Out-of-band `DROP` + recreate | Result |
|---|---|---|
| PG schema-per-tenant | same-shape restore | **No breakage.** Same backend pid, restored row read fine |
| PG schema-per-tenant | shape-changing restore (new column) | **No error.** Prepared statements re-plan. Only the pool's cached column list drifts — `reload_schema_cache!` refreshes it |
| PG schema-per-tenant | custom-type (enum) OID churn | **No breakage.** Enum OID changed; reads, filters, and writes all still correct |
| MySQL database-per-tenant | `DROP DATABASE` + recreate | **No breakage.** The session's default database re-resolves by name |
| PG database-per-tenant | `pg_terminate_backend` + `DROP DATABASE` + recreate | One request fails (`ConnectionNotEstablished`), then **AR self-heals on the next checkout** |

The enum case deserves a note: it was the one concrete mechanism an adversarial AI
panel produced against this conclusion (the PG adapter caches type OIDs on the
connection, and `reload_schema_cache!` does not clear that map). It was probed
directly. The OID did change; nothing broke.

### Why the original story was wrong

`search_path` was never "baked" into anything. The adapter puts a schema **name** in
the connection config
([`postgresql_schema_adapter.rb`](../../lib/apartment/adapters/postgresql_schema_adapter.rb)),
PostgreSQL resolves that name at query planning time, and a same-named schema
recreated underneath a live connection resolves exactly as before. The `UndefinedTable`
the adopter saw is a **missing container** — the window during which the schema does
not exist — not a stale pool. That window is already handled by the elevator's
missing-tenant fail-safe (see [`elevator-tenant-validation.md`](elevator-tenant-validation.md)),
and it closes on its own the moment the restore completes.

## The defect that is real: a two-sided footgun

Recovery was documented as a two-step: `PoolManager#remove_tenant(tenant)`, then
`Apartment.deregister_shard(pool_key)` for each removed pool. Both halves are public.
Probing each half **alone** shows they fail in opposite directions:

| Called alone | Consequence |
|---|---|
| `deregister_shard` without `remove_tenant` | **Wedges the tenant** for the life of the process: `ConnectionNotEstablished` on every switch, because `PoolManager` keeps handing back a pool ActiveRecord has forgotten |
| `remove_tenant` without `deregister_shard` | **Leaks** an ActiveRecord registration and a **live backend**, when the tenant is never re-accessed. (If it *is* re-accessed, `establish_connection` replaces and disconnects the old pool, which is why this leak hides in casual testing) |

So the seam the original design doc identified is real. It is a **resource-leak and
wedge seam**, not a recovery seam — and no helper is needed to close it, because the
correct thing is for neither half to be independently reachable.

**The fix**: `Apartment.deregister_shard` also removes the pool from `PoolManager`. It
becomes one whole operation that cannot leave the two registries disagreeing. Every
internal caller already removes from the manager before deregistering —
`PoolReaper#evict_tenant`, `Migrator#evict_migration_pools`, `AbstractAdapter#drop` —
so the change is a no-op for all of them.

Three details are load-bearing, and each was found by probing rather than reasoning.

**Order: ActiveRecord first, manager removal in an `ensure`.** The manager removal is
an in-memory delete that cannot meaningfully fail; AR's removal does IO and can raise.
Running the *fallible* step first, with the *infallible* one guaranteed after, means
the call always ends with both registries clear.

The reverse (manager-first) is a race, and it reintroduces the very wedge this fix
exists to remove. Between the manager delete and AR's removal, a concurrent tenant
switch misses the manager and calls `establish_connection` — which **returns the
still-registered old pool**, because `ConnectionHandler#establish_connection` reuses a
pool whose `db_config` is equal — and stores that doomed pool back in the manager. AR
then unregisters and disconnects it, and the manager is left holding a dead pool,
permanently. In the shipped order the same interleaving costs at most one failed
request. A regression spec drives a real switch inside the window; it fails under
manager-first ordering.

**The pool is disconnected explicitly, not left to ActiveRecord.** AR disconnects only
a pool it actually finds registered (`disconnect_pool_from_pool_manager` guards
`pool_config.disconnect!` behind `if pool_config`). A manager-held pool with *no*
matching AR registration is reachable — the integration suite swaps the
`ConnectionHandler` per example — and since we have just removed it from the manager,
no later `PoolManager#clear` will disconnect it either. Without an explicit
`disconnect!` its connections leak silently. This mirrors `AbstractAdapter#drop`, which
already removes, disconnects, then deregisters.

**The rescue path inside the pool-creation block must NOT use this method.**
`PoolManager`'s `@pools` is a `Concurrent::Map` whose MRI backend guards
`compute_if_absent` and `delete` with the **same non-reentrant mutex**. The
post-establish rescue in
[`connection_handling.rb`](../../lib/apartment/patches/connection_handling.rb) runs
*inside* the create block, so removing from the manager there raises `ThreadError:
deadlock; recursive locking` — which, being a `StandardError`, was swallowed by the
rescue and silently skipped the deregistration, orphaning the very pool the rescue
exists to reclaim. That path calls `Apartment.deregister_ar_shard` (the AR half only),
which is correct there anyway: `compute_if_absent` does not store the pool until the
block returns, so there is nothing in the manager to remove.

### `PoolManager` is internal

`PoolManager` is a cache, not the eviction API. Its mutating methods (`remove`,
`remove_tenant`, `evict_by_role`, `clear`) are marked `@api private`. Two reasons
beyond tidiness: `remove_tenant` bypasses the in-use guard the reaper honors
(`PoolReaper#pool_in_use?` refuses to evict a pool with a checked-out connection or an
open transaction; `PoolManager#remove_tenant` deletes the entry regardless), and it is
one half of the footgun above.

## The contract for out-of-band tenant DDL

For adopters restoring, rebuilding, or otherwise mutating a tenant's schema with a
tool that is not ActiveRecord:

1. **Do nothing to the pools.** The restore self-heals. This is the whole contract for
   the common case, and it is the part that surprises people.
2. **If the restore changed the table shape**, call
   `Apartment::Tenant.reload_schema_cache!(tenant)` so the pool's cached column list
   matches disk. Add `Model.reset_column_information` if a model's own column memo is
   also stale.
3. **Do not evict pools to "be safe."** With `schema_cache_per_tenant` enabled it is
   actively harmful: a fresh pool re-binds the **stale dump file** on creation, so
   eviction reintroduces the drift that `reload_schema_cache!` (which repopulates from
   the database) would have fixed.
4. **If you must discard pools** — a connection-config change, not a DDL change —
   `Apartment.reset_tenant_pools!` is correct and complete today.

Recovery is **process-local** in all cases. Nothing here reaches other workers; a
fleet-wide answer is still a rolling restart, or the deferred cross-process transport
seam noted in `elevator-tenant-validation.md`.

## Deferred: the remap case

The one failure that never self-heals is not DDL. v4 pools carry an **immutable
connection config**, keyed `tenant:role`. If a tenant is remapped to a different
database, host, or shard — or its credentials rotate — a warm pool keeps targeting the
**old** container indefinitely, and on a remap that means silently reading another
tenant's data.

`Apartment.reset_tenant_pools!` fixes this today, bluntly. A tenant-scoped helper
would fix it precisely. It is deferred, not rejected, on two grounds:

- **No adopter has hit it.** Naming and freezing an API for a hypothetical failure is
  how the refuted W3 narrative happened in the first place.
- **Deferral is cheap; premature shipping is not.** An API freeze forbids *removing*
  surface, not *adding* it. If remap bites, we design the helper against a real
  failure — with the in-use-guard question (which `remove_tenant` currently ignores)
  settled by that failure rather than guessed at now.

## What this supersedes

- `v4-beta-readiness.md` W3: "warm pool ... baked `search_path` ... schema cache full
  of now-dead table OIDs, so the next `switch` raises `PG::UndefinedTable`" — refuted.
- The same doc's framing of the fix as "promoting `evict_migration_pools` to tenant
  scope" — declined; the eviction primitive already exists in four internal places and
  a fifth public copy fixes nothing.
- `fixture-pool-lifecycle.md` member 9 — closed as **audited clean and refuted**, not
  as "documentation + helper."
