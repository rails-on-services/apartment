# W4 spike — PgBouncer / RDS Proxy and the libpq `options` path

Empirical result of the W4 driver spike called for in
[`v4-beta-readiness.md`](v4-beta-readiness.md). **It inverts W4's premise.** The gem change
that workstream was built around (set `search_path` via the libpq `options` connection
parameter) buys nothing against PgBouncer, while the thing that actually governs
correctness — a PgBouncer setting plus a PostgreSQL version floor — was not in scope at all.

## Verdict

1. **v4 on a stock PgBouncer in transaction mode silently reads other tenants' data.** Not a
   pin, not an error: wrong-tenant rows, no exception. See [The leak](#the-leak). This is
   shipped behavior today and the gem advertises PgBouncer compatibility as a goal. It needs
   a documented warning independent of any code change.
2. **The libpq `options` approach does not fix it, and can't.** PgBouncer *rejects* the
   `options` startup packet outright unless `search_path` is already in
   `track_extra_parameters` — and once it is, the plain `SET` path v4 uses today already works.
   See [The matrix](#the-matrix).
3. **Correctness under PgBouncer is governed by PostgreSQL 18 + one PgBouncer setting.**
   `search_path` was not reported to clients before PG 18, and PgBouncer can only track
   parameters the server reports. On PG ≤ 17, **no gem change and no PgBouncer config makes
   transaction-mode pooling safe.** See [The version floor](#the-version-floor).
4. **RDS Proxy behaves oppositely to PgBouncer: it pins rather than leaks.** Correct, but
   with the multiplexing benefit erased. Whether libpq `options` avoids the pin is the one
   open question the spike could not answer locally, and it is now the *only* thing that
   could justify the original W4 code change. See [RDS Proxy](#rds-proxy).
5. **Rails needs no patching either way.** `options` already reaches libpq untouched, and
   omitting `schema_search_path` already suppresses Rails' `SET`. See [The Rails side](#the-rails-side).

**Recommended re-scope:** W4 stops being a libpq-`options` implementation task and becomes
(a) a safety warning in the docs, shipped now; (b) a supported-configuration statement
(PgBouncer transaction mode requires PG 18+ and `track_extra_parameters`); (c) a CI job that
proves it; (d) a *separate*, evidence-gated question about RDS Proxy.

## The leak

PgBouncer 1.25.2, `pool_mode=transaction`, `default_pool_size=1`, stock
`track_extra_parameters` (the default, `IntervalStyle`). Two clients, each having issued
`SET search_path TO <tenant>` exactly as Rails' `configure_connection` does. Both are
multiplexed onto one backend (`pg_backend_pid()` identical), and the last `SET` wins for
everyone:

```
client A | search_path=tenant_b  read=BBB-tenant-b   >>> WRONG TENANT'S DATA <<<
client A | search_path=tenant_b  read=BBB-tenant-b   >>> WRONG TENANT'S DATA <<<
client B | search_path=tenant_b  read=BBB-tenant-b   ok
```

Client A asked for `tenant_a` and silently received `tenant_b`'s rows. No error is raised.
For a multi-tenancy gem this is the worst available failure mode, and it is reachable by an
adopter doing nothing more exotic than pointing v4 at a default PgBouncer.

Note this is *not* caused by anything v4 does wrong. It is inherent to session-scoped
`search_path` under transaction pooling, and v3 has it too — v3 more so, since it re-issues
the `SET` on every request.

## The matrix

Both tenants forced onto a single backend connection (`default_pool_size=1`); "safe" means
each client read only its own tenant's rows across interleaved queries.

| PostgreSQL | `track_extra_parameters` | app sets `search_path` via | Result |
|---|---|---|---|
| 18.4 | default | `SET` (v4 today) | **Silent cross-tenant leak** |
| 18.4 | default | libpq `options` | **FATAL at startup** — rejected |
| 18.4 | `+search_path` | `SET` (v4 today) | Safe, and genuinely multiplexed |
| 18.4 | `+search_path` | libpq `options` | Safe, and genuinely multiplexed |
| 16.14 | default | `SET` (v4 today) | **Silent cross-tenant leak** |
| 16.14 | `+search_path` | `SET` (v4 today) | **Silent cross-tenant leak** — tracking cannot work |
| 16.14 | `+search_path` | libpq `options` | Loud failure — every query `42P01` |

The rejection message, verbatim:

```
FATAL: unsupported startup parameter in options: search_path
```

Read the PG 18 rows together: `options` and `SET` land in exactly the same place, and the
column that decides the outcome is `track_extra_parameters`, not the application's method.
That is the whole argument against the original W4 plan.

## The version floor

`search_path` is absent from PostgreSQL's hard-wired ParameterStatus set until **PG 18**.
From the protocol docs:

> `search_path` was not reported by releases before 18.

Confirmed on the wire: `PQparameterStatus(conn, "search_path")` returns `"tenant_a"` on
PG 18.4 and `nil` on PG 16.14. PgBouncer's constraint is the complement — *"only parameters
reported by PostgreSQL to the client can be tracked"* — so on PG ≤ 17 its client-variable
cache can never learn `search_path`, and `track_extra_parameters = search_path` is accepted
but inert. That is precisely the PG 16 row above.

This corrects a claim carried in
[`apartment-v4.md`](apartment-v4.md) and [`v4-beta-readiness.md`](v4-beta-readiness.md): that
tracking `search_path` requires **Citus 12+**. That was true when written and is now
obsolete — vanilla PG 18 reports it. Citus 12 remains the only way to get it on PG ≤ 17,
because Citus backported the same `GUC_REPORT` flag.

## RDS Proxy

Not locally testable; this section is from AWS documentation, not the harness, and is
flagged accordingly.

RDS Proxy for PostgreSQL **pins** on `SET`, and pinning is *safe* — the connection stops
being shared, so no leak is possible. The cost is that multiplexing, the entire point of the
proxy, is gone. AWS is explicit: *"for PostgreSQL setting a variable leads to session
pinning"*, PostgreSQL has **no tracked-variable list** (unlike MySQL and SQL Server), and
**session pinning filters are not supported for PostgreSQL**. So v4 today on RDS Proxy is
correct and fully pinned.

Two things make the RDS Proxy story worse than it first looks, and they are independent of
Apartment:

- RDS Proxy also pins on **`nextval`/`setval`** and on non-transactional advisory locks. A
  Rails app that inserts rows or runs a migration is pinning for reasons that have nothing to
  do with tenancy.
- Its documented escape hatch — move the `SET` into the proxy's **initialization query** — is
  a *static, per-proxy* string. Per-tenant `search_path` cannot be expressed in it without one
  proxy per tenant, which does not scale to a real tenant list.

**The open question:** a libpq `options` startup parameter is not a `SET` command, so it may
not trip the pinning rule — but AWS does not document `options` at all, and if RDS Proxy
neither pins nor pool-keys on it, the result would be the *silent leak* rather than the safe
pin. It could plausibly be better, or plausibly be catastrophic. This is unresolved and
**must not be guessed at**; it needs a real RDS Proxy in AWS. It is the only surviving
rationale for the original W4 code change.

## The Rails side

Both halves of the original plan turn out to need no gem patch, which is worth recording even
though the plan is being re-scoped:

- **`options` already passes through.** `PostgreSQLAdapter` filters config through
  `PG::Connection.conndefaults_hash.keys`, and `:options` is a standard libpq conninfo
  keyword. An adopter can set it in `database.yml` today; verified on pg 1.6.3 / libpq 18.
- **Rails' `SET` is already suppressible.** `configure_connection` calls
  `self.schema_search_path = @config[:schema_search_path] || @config[:schema_order]`, and the
  setter is a no-op when handed `nil`. Omit the key and no `SET search_path` is issued at all.
  Identical across AR 7.2.3.1, 8.0.5, 8.1.3.

One caveat against ever advertising a connection as `SET`-free: `configure_connection`
unconditionally issues `SET intervalstyle`, `SET standard_conforming_strings`, and
`SET client_min_messages` regardless. Removing the `search_path` `SET` does not produce a
`SET`-free connection, and under RDS Proxy's rule those three pin the session anyway.

## Reproducing

Harness (PG 18 + PG 16 + PgBouncer 1.25.2, all local via Homebrew) is in the session
scratchpad: `pgbouncer.ini`, `matrix.rb`, `leak_detail.rb`, `probe_direct.rb`. It is small
enough to rebuild from this document, and should be rebuilt as a CI service-container job
rather than preserved as-is — see the recommendation below.

## Recommended re-scope of W4

Ordered by urgency, not by size.

1. **Ship the warning now.** Document that PgBouncer/RDS-Proxy transaction mode with
   schema-per-tenant is unsafe on PG ≤ 17 and unsafe on PG 18 without
   `track_extra_parameters = search_path`. This is a correctness warning against *shipped*
   behavior and should not wait for the rest of the workstream.
2. **State the supported configuration.** PgBouncer transaction mode is supported on
   **PG 18+** with `track_extra_parameters` including `search_path`; session mode is supported
   everywhere; transaction mode on PG ≤ 17 is **not supported** and cannot be made so.
3. **Prove it in CI.** A PgBouncer service container running the leak test as an assertion:
   the safe config isolates, and — worth pinning down explicitly — the unsafe config leaks. A
   test that fails if PgBouncer or PostgreSQL ever changes this behavior underneath us.
4. **Drop the libpq `options` implementation from the beta path.** It is dominated on
   PgBouncer. Re-open it *only* if the RDS Proxy question below comes back positive.
5. **Answer the RDS Proxy question separately, on real infrastructure.** Evidence-gated, like
   the member-10 disposition: build nothing until a measurement or an adopter says it matters.

Beta's correctness floor is met by 1–3, which are documentation, configuration, and a test —
not the M–L code long pole W4 was sized as. **The libpq `options` work, the thing W4 existed
to build, should not be built.**
