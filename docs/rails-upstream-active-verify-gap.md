# Draft: upstream Rails issue — `active?` does not detect an aborted transaction

**Not yet filed.** This is ours to report, not ours to fix. Apartment's checkin reset covers
only the tenant pools Apartment itself creates
([`designs/transaction-taint-detection.md`](designs/transaction-taint-detection.md), Never #4),
so the primary pool in every Rails application — Apartment or not — remains exposed. Shipping
our mitigation should not reduce the pressure for the upstream fix.

Verified on Rails 7.2, 8.0 and 8.1 against PostgreSQL 18.

---

**Title:** PostgreSQL: a connection in an aborted transaction passes `active?` and is served to the next caller

**Body:**

A PostgreSQL connection left in `PQTRANS_INERROR` is returned to the pool and handed out
again, because ActiveRecord's health check cannot see the state.

`PostgreSQLAdapter#active?` probes with `@raw_connection.query(";")`. **An empty query does
not error in an aborted transaction** — PostgreSQL returns `PGRES_EMPTY_QUERY` rather than
`ERROR: current transaction is aborted` — so `active?` returns `true`, `verify!` pronounces
the connection healthy, and `ConnectionPool#checkin` does not reset it. The next caller
receives a connection on which every statement raises `PG::InFailedSqlTransaction`,
indefinitely, until the process restarts.

### Reproduction

```ruby
conn = ActiveRecord::Base.connection
conn.begin_transaction
begin
  conn.execute('SELECT * FROM missing_table')
rescue ActiveRecord::StatementInvalid
  nil # swallowed by application code
end

conn.raw_connection.transaction_status  # => 3 (PG::PQTRANS_INERROR)
conn.open_transactions                  # => 1
conn.active?                            # => true    <-- the bug
```

The connection is then returned to the pool and reused:

```ruby
ActiveRecord::Base.connection_handler.clear_active_connections!(:all)

# same pooled connection, next checkout:
ActiveRecord::Base.connection.execute('SELECT 1')
# => ActiveRecord::StatementInvalid: PG::InFailedSqlTransaction:
#    ERROR:  current transaction is aborted, commands ignored until end of transaction block
```

### How you get into that state

An open transaction that ActiveRecord will not unwind, plus a statement it did not wrap. The
block form of `transaction` always resolves (PostgreSQL treats `COMMIT` on an aborted
transaction as `ROLLBACK`), so the reachable paths are the ones that bypass it: a raw
`execute("BEGIN")`, a `begin_transaction` without the block form, or a thread killed
mid-rollback.

### Prior art

This is the same class of defect as
[#12330](https://github.com/rails/rails/issues/12330) — a failed `DEALLOCATE` inside an
aborted transaction left a permanently broken prepared-statement cache, and the reporter's
summary was "all old app servers are now permanently broken without a restart." Same failure
shape, different cache. That one was fixed in Rails.

### Suggested fix

Either:

1. Have `active?` treat `PQTRANS_INERROR` as not-active, so the existing `verify!` →
   `reconnect!` path reclaims the connection; or
2. Reset on checkin when the raw connection reports an aborted transaction.

Option 1 is the smaller change and reuses machinery that already exists. The probe would need
to be something an aborted transaction actually rejects, or an explicit
`transaction_status` check.

### Why this bites harder for some applications than others

In a shared pool a poisoned connection is one of N, and the application mostly limps on until
it is recycled. Under a pool-per-tenant architecture (multi-tenancy gems in this ecosystem do
this) it can be the *only* connection for one tenant, so a single swallowed error takes that
tenant down on that worker while every other tenant looks healthy — and nothing in the logs
explains it.
