# Connection Poolers (PgBouncer, RDS Proxy)

How Apartment's PostgreSQL **schema** strategy interacts with an external connection pooler,
which configurations are safe, and which pooler to choose.

> [!WARNING]
> **PgBouncer in `transaction` pooling mode can silently serve one tenant another tenant's
> data** unless configured as described below, on PostgreSQL 18 or newer. There is no error
> and no exception — queries return the wrong tenant's rows.
>
> This affects the `:schema` strategy on **every version of Apartment, v3 and v4 alike**. It
> is a property of session-scoped `search_path` under transaction pooling, not a bug
> introduced by the gem. **Read [Choosing a pooler](#choosing-a-pooler) before putting a
> pooler in front of a schema-per-tenant app.**

## Contents

- [Verdict](#verdict)
- [Choosing a pooler](#choosing-a-pooler)
- [Why this happens](#why-this-happens)
- [PgBouncer — the supported option](#pgbouncer--the-supported-option)
- [RDS Proxy — not a pooling solution for Rails](#rds-proxy--not-a-pooling-solution-for-rails)
- [Verifying your setup](#verifying-your-setup)
- [Not affected](#not-affected)
- [Background](#background)

## Verdict

| Your setup | Verdict |
|---|---|
| No pooler | Safe |
| PgBouncer, `session` mode | **Safe** — works on every PostgreSQL version |
| PgBouncer, `transaction` mode, **PG 18+**, `track_extra_parameters` includes `search_path` | **Safe and genuinely multiplexed** — the recommended pooling setup |
| PgBouncer, `transaction` mode, PG 18+, default settings | **UNSAFE — silent cross-tenant reads** |
| PgBouncer, `transaction` mode, **PG ≤ 17** | **UNSAFE — cannot be made safe by any configuration** |
| RDS Proxy (PostgreSQL) | Safe, but **reduces no connections** — Rails pins it with or without Apartment |
| Database-per-tenant (`:database_name`) | Not affected — no `search_path` involved |

## Choosing a pooler

**Want transaction-level multiplexing?** PgBouncer on **PostgreSQL 18+** with
`track_extra_parameters = IntervalStyle,search_path`. This is the only configuration that
actually multiplexes a schema-per-tenant Rails app, and it needs **no changes to Apartment or
your application** — just the PgBouncer setting.

**On PostgreSQL ≤ 17?** Use PgBouncer in `session` mode, or upgrade PostgreSQL. Transaction
mode cannot be made safe below PG 18 — see [the version floor](#the-postgresql-18-requirement).

**Already running RDS Proxy for failover or IAM auth?** Keep it. Apartment works correctly
behind it. Just don't expect it to reduce your connection count — it won't, and it wouldn't
for a plain Rails app either.

**Adopting RDS Proxy *in order to* reduce connections?** Don't. It will pin every session and
give you nothing. See [RDS Proxy](#rds-proxy--not-a-pooling-solution-for-rails).

**Before reaching for any pooler**, check whether you need one. Apartment v4 pools per tenant
in-process and gives you a hard connection ceiling (`max_tenant_connections`) plus an idle-pool
reaper, and it ships gauges (`tenant_pools_live`, `backend_connections`) to tell you what your
real backend footprint is. Bounding connections in the gem is free; a pooler is infrastructure.
See [Pool Settings](../README.md#pool-settings) and [Observability](observability.md).

## Why this happens

The `:schema` strategy isolates tenants with PostgreSQL's `search_path`, which is
**session-scoped** state. Rails sets it once per connection, when the connection is
established.

Transaction-mode pooling hands a *different* backend connection to each transaction. A
`search_path` set by one client is therefore not guaranteed to be present — or to be the
*right one* — on the connection serving the next query. With several tenants sharing a
backend, the last `SET search_path` wins for everybody using it:

```
client A | asked for tenant_a | search_path=tenant_b | read tenant_b's rows   <-- WRONG
client B | asked for tenant_b | search_path=tenant_b | read tenant_b's rows       ok
```

Client A raises nothing. It reads the wrong tenant. An app that also *writes* writes to the
wrong tenant by the same mechanism.

**v4 narrows this but does not close it.** v3 issues `SET search_path` on every tenant switch
— essentially every request. v4 bakes the `search_path` into each pool's connection config, so
no `SET` runs per switch; Rails still runs one when it *establishes* each connection. Fewer
`SET`s is not zero `SET`s, and one is enough to poison a shared backend.

## PgBouncer — the supported option

### `session` mode (works everywhere)

```ini
[pgbouncer]
pool_mode = session
```

A client keeps its backend for the life of the connection, so `search_path` cannot be crossed.
Correct on every PostgreSQL version. You give up transaction-level multiplexing, which is
often why you deployed PgBouncer in the first place — but v4's pool-per-tenant model plus a
connection ceiling makes session mode practical where v3's per-request `SET` churn made it
painful.

### `transaction` mode (recommended; requires PostgreSQL 18+)

```ini
[pgbouncer]
pool_mode = transaction
track_extra_parameters = IntervalStyle,search_path
```

`track_extra_parameters` makes PgBouncer cache `search_path` **per client** and restore it onto
whichever backend serves that client's next transaction. Tenants stay isolated *and* genuinely
multiplex onto shared backends — verified, not assumed (see [Background](#background)).

Nothing changes on the Rails side. Your `database.yml` is unchanged; Apartment is unchanged.
Point the app at PgBouncer and set the two lines above.

Keep `IntervalStyle` in the list — it is PgBouncer's default, and Rails sets it on every
connection.

#### The PostgreSQL 18 requirement

**This requires PostgreSQL 18 or newer, and the requirement is not negotiable.** PgBouncer can
only track parameters the server *reports back* to the client, and `search_path` was **not
reported by PostgreSQL before version 18**.

On PG ≤ 17 the setting is accepted and silently does nothing. **You get the leak with a
configuration that looks correct** — which is the most dangerous state of all. Do not rely on
it there. Verify with `PQparameterStatus`:

```ruby
require 'pg'
c = PG.connect(host: 'your-db', dbname: 'your_db')
c.exec('SET search_path TO some_schema')
c.parameter_status('search_path')
# => "some_schema" on PG 18+ (PgBouncer can track it)
# => nil          on PG <= 17 (PgBouncer CANNOT track it — transaction mode is unsafe)
```

> [!NOTE]
> Citus 12+ backports the same server-side reporting, so `track_extra_parameters` also works on
> a Citus 12+ cluster running an older PostgreSQL.

### `transaction` mode on PostgreSQL ≤ 17

**Not supported. No configuration makes this safe**, and no change Apartment could make on its
side would fix it — the server simply does not tell the pooler what the `search_path` is. Use
`session` mode, or upgrade to PostgreSQL 18.

## RDS Proxy — not a pooling solution for Rails

**RDS Proxy is safe with Apartment — it *pins* rather than leaking — but it will not reduce
your connection count, and Apartment is not the reason.** A Rails application on RDS Proxy with
PostgreSQL pins its sessions **with or without this gem**. We do not support it as a
connection-pooling strategy because there is nothing we could change that would make it one.

### The pinning is Rails-level, not Apartment-level

This section is useful even if you don't use Apartment. RDS Proxy pins a session to a backend
the moment it sees session state it cannot track. For PostgreSQL it maintains **no
tracked-variable list at all** (unlike MySQL and SQL Server) and offers **no session pinning
filters** (again unlike MySQL) — so nothing can be whitelisted.

Four independent things trigger the pin in a normal Rails app. **Only the last is ours:**

| Trigger | Origin |
|---|---|
| Three unconditional `SET`s in `configure_connection` (`client_min_messages`, `standard_conforming_strings`, `intervalstyle`) | **Rails** — not configurable off |
| The extended query protocol, used **even when `prepared_statements: false`** | **Rails** — [rails/rails#40207](https://github.com/rails/rails/issues/40207), closed as stale, unresolved |
| `nextval`/`setval`, non-transactional advisory locks | **Rails** |
| Per-tenant `search_path` | Apartment |

Once pinned, a session holds its backend for the life of the client connection. With Rails'
long-lived pooled connections the mapping is effectively 1:1, and the proxy reduces nothing.
**Fixing Apartment's row while the other three stand would buy exactly nothing**, and two of
them cannot be fixed from a gem at all. Teams have resorted to monkeypatching
`ActiveRecord::ConnectionAdapters::PostgreSQLAdapter` to strip the `SET`s and move them into
the proxy's initialization query; it is heavy, and it still doesn't solve tenancy (below).

### Why the initialization query can't rescue tenancy

AWS's documented escape hatch is to move session setup into the proxy's **initialization
query**, so the `SET`s run when the *proxy* establishes a backend rather than from the client.
That works for static settings. It cannot work for a tenant's `search_path`: the initialization
query is **a single static string per proxy**, and a per-tenant value cannot be expressed in it
without running one proxy per tenant.

### Don't try to fix it with libpq `options`

Setting `search_path` via the libpq `options` startup parameter is the only mechanism that
*might* avoid the pin — it is not a `SET` command. **It is unverified and dangerous.** AWS does
not document `options` at all, and if the proxy neither pins on it nor keys its backend pool by
it, a backend carrying one tenant's `search_path` gets handed to another: the silent
cross-tenant read, in production. Do not attempt this without testing it first against a real
proxy (see [Verifying your setup](#verifying-your-setup)).

### What RDS Proxy is still good for

Failover resilience and IAM authentication — both of which work fine with Apartment. Just don't
buy it expecting fewer connections.

> [!NOTE]
> The RDS Proxy analysis above is drawn from AWS's documentation and from published reports,
> not from a test harness we run in CI (unlike the PgBouncer results, which are measured). If
> you have an RDS Proxy available, we would welcome a verified report — see
> [Verifying your setup](#verifying-your-setup) for the test.

## Verifying your setup

**Do not take the configuration on trust. The failure is silent, so a working app proves
nothing.** Point two connections at two tenants through your pooler, force them to share a
backend, and confirm each reads only its own data.

```ruby
require 'pg'

def client(tenant)
  c = PG.connect(host: POOLER_HOST, port: POOLER_PORT, dbname: DB)
  c.exec("SET search_path TO #{tenant}")
  c
end

a = client('tenant_a')
b = client('tenant_b')

3.times do
  # pg_backend_pid identical across a and b => genuinely multiplexed => the case that matters.
  puts a.exec('SELECT current_schema(), pg_backend_pid()').values.inspect
  puts b.exec('SELECT current_schema(), pg_backend_pid()').values.inspect
end
```

**If `a` ever reports `tenant_b`, your configuration is unsafe — stop and fix it.**

Two notes on making the test meaningful:

- Set PgBouncer's `default_pool_size = 1` while testing. This forces both clients onto one
  backend and makes the failure reproducible instead of intermittent.
- If `pg_backend_pid()` differs between `a` and `b`, they are *not* sharing a backend and the
  test has proven nothing yet. On RDS Proxy, differing pids are the expected signal that the
  sessions have **pinned** — confirm with the `DatabaseConnectionsCurrentlySessionPinned`
  CloudWatch metric.

## Not affected

- **Database-per-tenant** (`tenant_strategy = :database_name`, PostgreSQL or MySQL). Each
  tenant is a distinct database, so tenant identity lives in the connection itself rather than
  in session state. Poolers key their backend pools by database, so there is nothing to cross.
- **Pinned models** (`pin_tenant`). Apartment qualifies their table names to the default
  tenant, so they resolve correctly regardless of `search_path`.

## Background

The full empirical result — the matrix across PostgreSQL 16/18, PgBouncer 1.25, and both the
`SET` and libpq `options` paths, with `pg_backend_pid()` used to prove genuine multiplexing —
is in [`docs/designs/w4-pgbouncer-libpq-spike.md`](designs/w4-pgbouncer-libpq-spike.md). It
also records why setting `search_path` via the libpq `options` parameter is **not** the fix it
appears to be: PgBouncer rejects the `options` startup packet outright
(`FATAL: unsupported startup parameter in options: search_path`) unless you have already
applied the `track_extra_parameters` setting that makes `options` unnecessary.
