# Connection Poolers (PgBouncer, RDS Proxy)

How Apartment's PostgreSQL **schema** strategy interacts with an external connection pooler,
and which configurations are safe.

> [!WARNING]
> **PgBouncer in `transaction` pooling mode can silently serve one tenant another tenant's
> data** unless it is configured as described below, on PostgreSQL 18 or newer. There is no
> error and no exception — queries return the wrong tenant's rows.
>
> This affects the `:schema` strategy on **every version of Apartment, v3 and v4 alike**. It
> is a property of session-scoped `search_path` under transaction pooling, not a bug
> introduced by the gem. **Read [Safe configurations](#safe-configurations) before putting a
> pooler in front of a schema-per-tenant app.**

## TLDR

| Your setup | Verdict |
|---|---|
| No pooler | Safe |
| PgBouncer, `session` mode | Safe |
| PgBouncer, `transaction` mode, **PG 18+**, `track_extra_parameters` includes `search_path` | Safe |
| PgBouncer, `transaction` mode, PG 18+, default settings | **UNSAFE — silent cross-tenant reads** |
| PgBouncer, `transaction` mode, **PG ≤ 17** | **UNSAFE — cannot be made safe** |
| RDS Proxy (PostgreSQL) | Safe, but sessions pin — you lose the multiplexing you paid for |
| Database-per-tenant strategy (`:database_name`) | Not affected — no `search_path` involved |

## Why this happens

The `:schema` strategy isolates tenants with PostgreSQL's `search_path`, which is
**session-scoped** state. Rails sets it once per connection, when the connection is
established.

Transaction-mode pooling hands a *different* backend connection to each transaction. A
`search_path` set by one client is therefore not guaranteed to be present — or to be the
*right one* — on the connection serving the next query. With several tenants sharing a
backend, the last `SET search_path` wins for everybody using it.

Concretely, with two tenants multiplexed onto one PgBouncer backend:

```
client A | asked for tenant_a | search_path=tenant_b | read tenant_b's rows   <-- WRONG
client B | asked for tenant_b | search_path=tenant_b | read tenant_b's rows       ok
```

Client A raises nothing. It simply reads the wrong tenant. In an app that also *writes*,
the same mechanism writes to the wrong tenant.

**v4 narrows this but does not close it.** v3 issues `SET search_path` on every tenant switch
— i.e. on essentially every request. v4 bakes the `search_path` into each pool's connection
config, so no `SET` runs per switch; Rails still runs one when it *establishes* each
connection. Fewer `SET`s is not zero `SET`s, and one is enough to poison a shared backend.

## Safe configurations

### PgBouncer — `session` mode (works everywhere)

```ini
[pgbouncer]
pool_mode = session
```

A client keeps its backend for the life of the connection, so `search_path` cannot be
crossed. This is the simplest correct answer and it works on every PostgreSQL version. You
give up transaction-level multiplexing, which is often the reason you deployed PgBouncer;
v4's pool-per-tenant model plus a connection ceiling (see
[Pool Settings](../README.md#pool-settings)) is what makes session mode practical where v3's
per-request `SET` churn made it painful.

### PgBouncer — `transaction` mode (requires PostgreSQL 18+)

```ini
[pgbouncer]
pool_mode = transaction
track_extra_parameters = IntervalStyle,search_path
```

`track_extra_parameters` makes PgBouncer cache `search_path` per *client* and restore it onto
whichever backend serves that client's next transaction. With it, tenants stay isolated
**and** genuinely multiplex onto shared backends.

**This requires PostgreSQL 18 or newer, and the requirement is not negotiable.** PgBouncer
can only track parameters the server reports back to the client, and `search_path` was not
reported by PostgreSQL before version 18. On PG ≤ 17 the setting is accepted and silently
does nothing — you get the leak with a config that looks correct. Do not rely on it there.

Keep `IntervalStyle` in the list; it is PgBouncer's default and Rails sets it on every
connection.

> [!NOTE]
> Citus 12+ backports the same server-side reporting, so `track_extra_parameters` also works
> on a Citus 12+ cluster running an older PostgreSQL.

### PgBouncer — `transaction` mode on PostgreSQL ≤ 17

**Not supported. There is no configuration that makes this safe**, and no change Apartment
can make on its side to fix it. Use `session` mode, or upgrade to PostgreSQL 18.

### RDS Proxy (PostgreSQL)

**Safe, but it pins.** RDS Proxy pins a session to a backend as soon as the client issues any
`SET` — which Rails does on every new connection — so the connection stops being shared and
no cross-tenant leak is possible. The trade-off is that transaction-level multiplexing, the
point of the proxy, does not happen for your tenant connections.

This is a property of RDS Proxy's PostgreSQL support, not of Apartment: it maintains no
tracked-variable list for PostgreSQL (unlike MySQL and SQL Server), and session pinning
filters are not available for PostgreSQL. Note that a Rails app pins for unrelated reasons
anyway — RDS Proxy also pins on `nextval`/`setval` and on non-transactional advisory locks.

Its documented escape hatch, moving the `SET` into the proxy's **initialization query**, does
not help here: that query is a single static string per proxy, and a per-tenant `search_path`
cannot be expressed in it without running one proxy per tenant.

If you need real multiplexing in front of a schema-per-tenant app on AWS, PgBouncer on
PostgreSQL 18 with `track_extra_parameters` is currently the only configuration that
provides it.

## Verifying your setup

Do not take the configuration on trust — the failure is silent, so a working app proves
nothing. Point two connections at two tenants through your pooler, force them to share a
backend, and confirm each reads its own data:

```ruby
require 'pg'

# Two clients, two tenants, through the pooler.
a = PG.connect(host: POOLER_HOST, port: POOLER_PORT, dbname: DB)
b = PG.connect(host: POOLER_HOST, port: POOLER_PORT, dbname: DB)
a.exec('SET search_path TO tenant_a')
b.exec('SET search_path TO tenant_b')

# Same backend pid => genuinely multiplexed => this is the case that matters.
3.times do
  puts a.exec('SELECT current_schema(), pg_backend_pid()').values.inspect
  puts b.exec('SELECT current_schema(), pg_backend_pid()').values.inspect
end
```

If `a` ever reports `tenant_b`, your configuration is unsafe. Set PgBouncer's
`default_pool_size = 1` while testing to force backend sharing and make the failure
reproducible.

## Not affected

- **Database-per-tenant** (`tenant_strategy = :database_name`, on PostgreSQL or MySQL). Each
  tenant is a distinct database, so tenant identity lives in the connection itself rather than
  in session state. Poolers key their backend pools by database, so there is nothing to cross.
- **Pinned models** (`pin_tenant`). Apartment qualifies their table names to the default
  tenant, so they resolve correctly regardless of `search_path`.

## Background

The full empirical result — the test matrix across PostgreSQL 16/18, PgBouncer 1.25, and both
the `SET` and libpq `options` paths — is in
[`docs/designs/w4-pgbouncer-libpq-spike.md`](designs/w4-pgbouncer-libpq-spike.md), including
why setting `search_path` via the libpq `options` connection parameter does **not** solve this
(PgBouncer rejects it outright unless you have already applied the `track_extra_parameters`
fix that makes it unnecessary).
