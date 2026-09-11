# PostgreSQL Type-Map Sharing Across Tenant Pools

## TLDR

Every new PostgreSQL connection Rails opens rebuilds the OID type map from scratch: `configure_connection` ends in `reload_type_map`, which runs three `pg_type` queries. Two of the three have no usable index and sequential-scan `pg_type`, whose size grows by two rows per table per tenant schema. Pool-per-tenant turns "a handful of connects at boot" into "a connect per tenant per nightly pass", so the cost is paid thousands of times a night against a catalog that is hundreds of times larger than a single-schema app's. Measured: 3.4 ms of type-map queries per connect at 5 schemas, 65 ms at 500.

The fix shares one type map per **database** across every adapter in the process. It prepends two public, `:nodoc:` methods on `PostgreSQLAdapter` (`clear_cache!` and `reload_type_map`), builds the map into a `HashLookupTypeMap` subclass whose mapping is a `Concurrent::Map`, and publishes it in a process-wide registry keyed by host, port, database and default timezone. A new physical connection adopts the shared map; only an explicit reload after enum DDL rebuilds it. No private ActiveRecord method is overridden, and the apply step fails closed if the two seams disappear.

Upstream has fixed the connect-time cost on Rails main (rails/rails#57013, merged 2026-03-28, unreleased as of 8.1.3.1): built-in OIDs ship statically and the one remaining `pg_type` scan is deferred to the first unknown type, per adapter. This patch is the bridge for 7.2 through 8.1, and on main it still turns that deferred per-adapter scan into a per-process one.

## Contents

- [Problem](#problem)
- [What was measured](#what-was-measured)
- [Mitigations compared](#mitigations-compared)
- [Design](#design)
- [Concurrency](#concurrency)
- [DDL and staleness](#ddl-and-staleness)
- [Testing](#testing)
- [Non-goals](#non-goals)
- [Upstream](#upstream)

## Problem

`PostgreSQLAdapter#initialize_type_map` registers the built-in types by name, then calls `load_additional_types`, which asks `pg_type` three questions through `OID::TypeMapInitializer`:

1. `WHERE t.typname IN (...)`: the OIDs of every known type name. Uses the `(typname, typnamespace)` index; flat cost.
2. `WHERE t.typtype IN ('r', 'e', 'd')`: every range, enum and domain type in the database. No index on `typtype`; sequential scan.
3. `WHERE t.typelem IN (...)`: every array type whose element is a known OID. No index on `typelem`; sequential scan.

Each query also `LEFT JOIN`s `pg_range`. The result is stored in `@type_map`, an instance variable on the adapter: nothing shares it across connections, and the schema cache (`db/schema_cache.yml`) covers columns and indexes only.

Every physical connection pays this. `verify!` calls `reconnect!` when the socket is not yet open, `reconnect!` calls `configure_connection`, and `configure_connection` ends in `reload_type_map`, which clears the map and calls `initialize_type_map` again. `reset!` takes the same path. So a pool that is evicted and rebuilt pays the full load again, and so does a reconnect after a network blip.

Schema-per-tenant makes `pg_type` large. PostgreSQL creates a composite type and its array type for every table, so each tenant schema adds roughly two `pg_type` rows per table. At about 220 tables per schema, 570 tenant schemas add roughly 250,000 rows. Two of the three queries scan all of them on every connect.

Pool-per-tenant makes connects frequent. v4 gives each `tenant:role` its own pool, and the reaper evicts a pool after `pool_idle_timeout` (300 s default; the reporting adopter runs 120 s) or when `max_tenant_pools` forces an LRU eviction. A nightly job that iterates every tenant touches most of them once per pass, so every switch in the next pass is a cold pool: a fresh connection, a fresh type map, three more catalog scans.

This is a v4 property. v3 switched `search_path` on one shared pool, so its connections lived for the life of the process and the type map was built once per connection slot.

## What was measured

Reported on a v4 alpha lane (Rails 8.1.3.1, PostgreSQL 18, 4 vCPU): the two scanning statements ran at about 1 call/s all day and 3 to 15 calls/s during the nightly tenant sweep, peaking at 14 calls/s and about 6 average active sessions. They were the top two statements by load overnight. The v3 production database, with one shared pool, does not show them in its top 25.

Spike (laptop, PostgreSQL 18.6, Rails 8.1.3.1, 220 tables per schema, median of five fresh connects each; script and JSON in the reporting adopter's evidence directory):

| schemas | `pg_type` rows | `pg_type` size | type-map queries | connect, total |
|---|---|---|---|---|
| 5 | 2,821 | 792 kB | 3.4 ms | 9.8 ms |
| 50 | 22,621 | 5.6 MB | 7.1 ms | 16.5 ms |
| 500 | 220,621 | 53 MB | 64.5 ms | 97 ms (61 to 197) |

The `typname` query stays at 2 to 3 ms throughout. The `typtype` and `typelem` queries go from 0.6 ms each to 29 and 33 ms; at 500 schemas each plans as a parallel sequential scan with two workers, so one connect occupies up to three backends for the duration. A laptop with NVMe is a lower bound for a managed instance.

Checked against the reporting adopter's real catalogs on 2026-09-11 (read replicas, PostgreSQL 18.3, `EXPLAIN (ANALYZE, BUFFERS)`, every buffer a cache hit):

| database | `pg_type` rows | `pg_type` size | namespaces | tables | `typtype` scan | `typelem` scan | `typname` lookup |
|---|---|---|---|---|---|---|---|
| production | 281,927 | 85 MB | 669 | 140,710 | 11.4 ms | 12.6 ms | 0.12 ms |
| staging | 280,375 | 103 MB | 677 | 139,934 | 20.5 ms | 20.8 ms | not run |

Both scans plan as a Gather over two parallel workers, so roughly 24 ms of wall clock per connect on production is about 70 ms of backend CPU, and about 40 ms on staging is about 120 ms. The two catalogs are the same size: the v4 lane that reported the symptom is not a small-catalog environment paying a small per-call cost many times, it is paying the production-sized cost many times.

There is a fourth `pg_type` statement per connect, in `add_pg_decoders` (`SELECT t.oid, t.typname FROM pg_type WHERE t.typname IN (...)`). It is index-driven and stays cheap; this design leaves it alone.

## Mitigations compared

### Configuration only: keep pools alive across the pass

Raise `pool_idle_timeout` and `max_tenant_pools` so tenant pools survive from one nightly pass to the next.

Rejected. With `max_tenant_pools` below the tenant count, LRU admission evicts every pool once per pass no matter what the idle timeout says: 570 tenants through a 50-pool cap is 570 cold connects per pass. Raising the cap to the tenant count keeps `tenant_count × tenant_pool_size` connections open per process (1,140 at a pool size of 2), which is the connection budget [pool-connection-budget.md](pool-connection-budget.md) exists to bound, multiplied by the number of processes. It also holds connections that an each-tenant iteration idiom deliberately releases after every tenant.

### Reaper policy: keep the pool, close its sockets

Keep the pool object and its adapter instances across idleness, close only the sockets, and hope the type map survives on the adapter.

Rejected on inspection of ActiveRecord. `ConnectionPool#disconnect` calls `disconnect!` on each adapter and then empties `@connections`, so the adapter objects are discarded with their `@type_map`. Even an adapter that were retained rebuilds the map on its next use: `verify!` -> `reconnect!` -> `configure_connection` -> `reload_type_map`, which clears the map first. Nothing in ActiveRecord retains a type map across a socket close, so this policy cannot be implemented without the sharing below, and with the sharing below it is unnecessary.

### Type-map sharing (chosen)

Build the type map once per database and hand the same instance to every adapter that connects to that database. OIDs are database-wide; nothing in the map depends on `search_path`, the role, or the tenant. The only connection-level input is `default_timezone`, which `initialize_type_map` bakes into the `time` and `timestamp` registrations, so it is part of the key.

## Design

### Components

`Apartment::Patches::PostgresqlTypeMap` is a module prepended on `ActiveRecord::ConnectionAdapters::PostgreSQLAdapter`. It carries:

- `SharedTypeMap < ActiveRecord::Type::HashLookupTypeMap`: same public surface, but `@mapping` is a `Concurrent::Map` instead of a plain `Hash`. See [Concurrency](#concurrency).
- `REGISTRY`: a process-wide `Concurrent::Map` from `[host, port, database, default_timezone]` to a `SharedTypeMap`.
- Two overrides, both of public `:nodoc:` methods present unchanged on Rails 7.2, 8.0, 8.1 and main.
- `.apply!(adapter_class)`: the shape guard and the prepend, fail-closed.
- `.reset!`: empties the registry. For test suites that need a cold start; not a configuration knob.

### The two seams

**`clear_cache!(new_connection: false)`.** Rails calls `clear_cache!(new_connection: true)` from `reconnect!`, `disconnect!` and `reset!`: it is ActiveRecord's own signal that a physical connection is being replaced and connection-derived caches should be dropped (the PostgreSQL adapter already uses it to drop `@schema_search_path`). The override calls `super`, then sets `@type_map = nil` when `new_connection` is true. A freshly built adapter has `@type_map = nil` from `initialize`, so every path that leads to a new socket arrives at `reload_type_map` with a nil map.

**`reload_type_map`.** Under the adapter's own `@lock`, exactly as upstream:

- `@type_map` nil (a new physical connection): adopt `REGISTRY[key]` if present; otherwise build a `SharedTypeMap`, run `initialize_type_map` into it, and publish with `put_if_absent`. If another thread published first, adopt theirs and drop ours.
- `@type_map` live (an explicit reload after DDL): build a fresh `SharedTypeMap`, run `initialize_type_map` into it, and overwrite `REGISTRY[key]`. Other adapters keep the instance they hold until their next physical reconnect. This is the only path that ever replaces a published map, and the only callers are the enum DDL helpers (`create_enum`, `drop_enum`, `rename_enum`, `add_enum_value`, `rename_enum_value`) plus `disable_extension`.

The build writes into the adapter's own `@type_map` before publishing because `initialize_type_map` loads through the private `type_map` reader, not through its argument: `load_additional_types` constructs `TypeMapInitializer.new(type_map)`. That reader is the one private dependency; it is exercised, not overridden.

### Fail-closed apply

`apply!` raises `Apartment::ConfigurationError` when the adapter class lacks a public `reload_type_map`, a public `clear_cache!`, or a private `initialize_type_map`, resolved with `method_defined?` / `private_method_defined?` so a method that merely moved to a superclass still counts (the same rule as `Patches::ConnectionRegistry`). Refusing to boot is preferable to silently reinstating the per-connection load: the failure this patch prevents is a capacity failure that shows up as database saturation overnight, which is far harder to attribute than a boot error naming the ActiveRecord version.

### Apply point

Prepended from `ActiveSupport.on_load(:active_record_postgresqladapter)` at gem load, the same hook `Patches::PostgresqlSequenceName` uses, not from `activate!`. Two reasons. Boot opens connections before `activate!` runs (schema cache load, pending-migration check, `connects_to`), and the map those connections build should be the one tenant pools adopt. And the patch is correct for any PostgreSQL connection, tenant or not: a second database in the app gets its own key. MySQL and SQLite consumers never load the PostgreSQL adapter, so the hook never fires for them.

## Concurrency

A type map shared across threads and fibers has two kinds of access:

- **Reads** on every column resolution: `fetch`, `lookup`, `key?`. These are the hot path.
- **Writes** at two moments: the initial build (many `register_type` / `alias_type` calls on an instance nobody else holds yet), and lazy registration of an OID that was not in the catalog when the map was built. `get_oid_type` runs `load_additional_types([oid])` for an unknown OID, or registers `Type.default_value` for one PostgreSQL does not know either. These are rare and per process now rather than per connection.

Upstream `HashLookupTypeMap` keeps `@mapping` in a plain `Hash` and `@cache` in a `Concurrent::Map`. Sharing it as-is would be correct on MRI: `Hash#fetch`, `Hash#key?`, `Hash#[]=` and `Hash#keys` are single C calls that never release the GVL for Integer and String keys, the class has no Ruby-level iteration over `@mapping` (its `perform_fetch` is a `Hash#fetch`, unlike `Type::TypeMap`'s `reverse_each.detect`), and `Hash#[]=` never yields, so a fiber cannot switch mid-write. `Concurrent::Map` on MRI is built on precisely this argument.

The design does not leave it implicit. `SharedTypeMap` swaps `@mapping` for a `Concurrent::Map`, the primitive Rails already chose for the other half of the same object. Writes are then serialized by the map's own lock and reads stay lock-free, on MRI and on any other runtime concurrent-ruby supports. Every operation the adapter and `TypeMapInitializer` perform on the store (`[]=`, `fetch(key, default)`, `key?`, `keys`, `clear`) exists on `Concurrent::Map` with the same semantics.

Two more properties are load-bearing:

- **No lock is held across I/O.** The registry publishes with `put_if_absent`, not `compute_if_absent`: the catalog queries run on the caller's connection outside any registry lock, and a lost race costs one redundant build (today's cost, once) rather than blocking every other database's first connection behind a slow catalog. The adapter's own `@lock` is held exactly as upstream holds it in `reload_type_map`.
- **A published map is never cleared.** Upstream's `reload_type_map` does `type_map.clear` then rebuilds in place, which on a shared instance would leave every other connection with an empty map mid-rebuild. The override builds a new instance and replaces the registry entry instead. Holders of the previous instance continue to resolve against it; the worst they see is a missing OID, which `get_oid_type` fills in lazily, exactly as a stale per-connection map does today.

Partial visibility during a lazy registration is benign: `TypeMapInitializer#run` registers one OID at a time, and a reader that misses one loads it itself, producing an identical registration. The one shared side effect is `register_type` calling `@cache.clear`, which now drops the lookup memo for every holder instead of one connection; it fires only on lazy registration, so a handful of times per process.

## DDL and staleness

| Event | Today (per connection) | With sharing |
|---|---|---|
| Enum DDL through the adapter helpers | The executing connection reloads; others learn the new OID lazily via `get_oid_type`. | The executing connection rebuilds and republishes; others keep their instance and learn lazily, identical to today. Fresh connections adopt the rebuilt map with no lazy load. |
| `CREATE TYPE` via raw `execute` | No reload anywhere; lazy `get_oid_type` on first sight. | Same; the lazy registration is now shared, so one connection's discovery serves the process. |
| New tenant schema | Nothing: a table's composite and array types are never registered (query 3 matches arrays of built-in OIDs only). | Same. Creating tenants does not require any reload. |
| `DROP TYPE` | The dropped OID stays registered on connections that had it; a fresh connection would not have it. | The dropped OID stays in the shared map until the next DDL-helper reload or `reset!`. Harmless: a result row can only carry that OID if the type exists. |
| OID reuse after drop and recreate | A warm connection with the old registration mis-types the new type until it reconnects. | Same failure surface, now shared. PostgreSQL does not reuse OIDs while the counter has not wrapped (2^32), so this is theoretical; the existing out-of-band enum-churn spec continues to exercise the recreated-enum case. |
| Reconnect after a network error | Full rebuild. | Adopts the shared map; zero catalog queries. |

## Testing

Unit (`spec/unit/patches/postgresql_type_map_spec.rb`, PG-gated like the sequence-name spec, run under `PG_UNIT_REQUIRED=1` in the postgresql CI job):

- `SharedTypeMap` keeps its mapping in a `Concurrent::Map` and round-trips the surface the adapter and `TypeMapInitializer` use. This is the guard for the one internal dependency: if `HashLookupTypeMap` stops storing in `@mapping`, the round-trip lands in a Hash the subclass does not own and the assertion fails.
- `apply!` raises `ConfigurationError` for each missing seam and is idempotent.
- Against a fake adapter with upstream's `reload_type_map` shape: one build per database key shared across adapters; distinct keys for distinct databases and timezones; a live-map reload rebuilds and republishes while other holders keep their instance; `clear_cache!(new_connection: true)` makes the next reload adopt; `new_connection: false` does not; `reset!` forces a rebuild; concurrent first connections converge on one instance.

Integration (`spec/integration/v4/postgresql_type_map_spec.rb`, PostgreSQL only, 7.2 through main via appraisal):

- The first cold connection after a registry reset loads (three statements on 7.2 to 8.1, zero on main), and the nine cold connections that follow, with every tenant pool evicted between rounds (`Apartment.reset_tenant_pools!`), load nothing; without the patch each would.
- Each fresh connection still runs exactly one `add_pg_decoders` statement, pinning that the decoder path was not touched. Pends on main, where there is no lookup.
- `create_enum` on one tenant's connection republishes: a fresh connection resolves the new type without a `WHERE t.oid IN` lazy load. Pends on main, whose rebuild registers well-known types only.
- A type created by raw DDL is learned lazily once and then served to every later cold connection with no further query. This is the example that carries the sharing claim on main.
- The real `PostgreSQLAdapter` has the module in its ancestors (the `on_load` hook fired).

## Non-goals

- Sharing `add_pg_decoders` output. Decoders are set on the raw `PG::Connection` and the lookup is index-driven; not worth a second seam.
- Persisting the type map to the schema cache. That is the upstream proposal (below) and needs invalidation machinery this gem should not own.
- Any new configuration option. The behavior is unconditional for PostgreSQL adapters; `reset!` is a test hook, not a knob.

## Upstream

- **rails/rails#57013 (merged 2026-03-28, Rails main, not in 8.1.3.1)** removes the connect-time queries. `OID::WellKnown` ships the built-in OIDs as a static table keyed by server version, so `initialize_type_map` registers them without touching the catalog and `add_pg_decoders` needs no lookup either. `load_additional_types` becomes on-demand: the first unknown OID an adapter meets triggers one query that unions the requested OIDs with the old bulk `typtype IN ('r', 'e', 'd')` filter (now excluding `pg_catalog`), tracked per adapter by `@type_map_queried`, which `reload_type_map` resets. Both seams this patch uses survive unchanged there, and `HashLookupTypeMap#initialize` dropped its `parent` argument, which is why `SharedTypeMap` forwards whatever it receives. On main the patch's remaining value is that the deferred bulk scan runs once per process rather than once per adapter; the integration spec feature-detects `OID::WellKnown` and pends the two connect-time examples there.
- rails/rails#46409 and rails/rails#44478 propose storing the type map in the schema cache or sharing it across a pool. Both open and unmerged as of this writing.
- rails/rails#49976 reported the same symptom with Apartment on Rails 7.1 and was closed as an unsupported use of the adapter.

If upstream lands pool-level sharing, this patch becomes redundant and `apply!`'s shape guard is where the conflict will surface first. When the gem's floor reaches the release that carries #57013, the patch can be reduced to the deferred-scan sharing or dropped; measure the deferred scan under a tenant sweep before deciding.
