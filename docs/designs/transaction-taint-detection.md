# Transaction Taint Detection (W1 / failure-class member 7)

Status: living. Design for `PQTRANS_INERROR` taint detection, and the reasoned
rejection of every recovery shape. Supersedes the scope sketched for W1 in
[`v4-beta-readiness.md`](v4-beta-readiness.md) and for member 7 in
[`fixture-pool-lifecycle.md`](fixture-pool-lifecycle.md); both proposed "a recovery
path in `Apartment::Tenant.switch`'s ensure block," which the evidence below
refutes.

## Verdict

- **Ship detection, not recovery.** A named instrumentation event plus a warning at the
  switch boundary. No `ROLLBACK`, no savepoint, no connection reset. See
  [What we ship](#what-we-ship).
- **A raw `ROLLBACK` recovery is actively dangerous, and it is what the workaround in
  the field does.** It silently destroys the *enclosing* transaction, desyncs
  ActiveRecord's bookkeeping, raises nothing, and lets subsequent writes autocommit and
  leak across examples. See [Evidence B](#evidence-b--the-savepoint-regression-is-silent).
- **Savepoint containment inside `switch` is structurally unavailable**, not merely
  expensive: a `SAVEPOINT` needs a connection, and at switch entry the tenant's pool
  has none. See [Never #2](#never).
- **No gem in the ecosystem heals a poisoned pooled connection.** The convention,
  including in the one other PostgreSQL schema-switching gem, is detect-and-avoid. See
  [Prior art](#prior-art--what-the-ecosystem-actually-does).
- **v4 already closed half of this failure class by construction.** v3's `search_path`
  mutation would have had the exact bug chronomodel works around; v4's `switch` executes
  no SQL. Lock it with a regression test. See [The v4 dividend](#the-v4-dividend).
- **Production taint is real but is a Rails gap, not ours.** A connection in a failed
  transaction passes AR's health check and is handed to the next caller. Report it
  upstream; do not paper over it. See [The upstream Rails gap](#the-upstream-rails-gap).

## Contents

- [The mechanism](#the-mechanism)
- [Evidence](#evidence)
- [The v4 dividend](#the-v4-dividend)
- [Prior art — what the ecosystem actually does](#prior-art--what-the-ecosystem-actually-does)
- [What we ship](#what-we-ship)
- [Never](#never)
- [The upstream Rails gap](#the-upstream-rails-gap)
- [Open questions](#open-questions)
- [Cross-references](#cross-references)

## The mechanism

**A PostgreSQL connection enters `PQTRANS_INERROR` when a statement fails inside a
transaction.** Every subsequent statement on it raises `PG::InFailedSqlTransaction`
until the transaction ends. That much is PostgreSQL, not Rails and not Apartment.

**ActiveRecord heals this automatically whenever the failing statement is inside an AR
transaction block**, because the `TransactionManager` unwinds via `ROLLBACK` or
`ROLLBACK TO SAVEPOINT`. Verified: a failure inside `transaction(requires_new: true)`
leaves the connection `INTRANS`, fully usable.

**The taint therefore survives only in the gap:** a statement AR did not wrap, failing
while a transaction AR will not unwind stays open. Two populations land in that gap.

| | Fixture pool (pinned) | Production pool |
|---|---|---|
| Who holds the transaction open | the fixture transaction | app code (`begin_transaction` without a block, raw `execute("BEGIN")`, a thread killed mid-rollback) |
| Typical tainting statement | raw `execute`, DDL, a query against a missing table | same |
| Does AR heal it? | at teardown, yes | **never** |
| Outlives the example / request? | no | **yes, indefinitely** |
| Does `checkin` fire? | no (pinned connections skip checkin) | yes, but it does not reset |
| Blast radius | rest of the example, one tenant | that tenant, on that worker, until process restart |

**Apartment's contribution is amplification, not causation.** Pool-per-tenant means the
poisoned connection belongs to *one tenant*, so the production failure shape is "one
tenant is dead on one worker while every other tenant is fine, and nothing in the logs
explains why." That is why the gem should name the tenant, and it is the whole
justification for detection living here.

## Evidence

Reproduced against PostgreSQL 18 / Rails 8.1, driving the real
`setup_fixtures` / `teardown_fixtures` lifecycle. Not mocked. The probes become the
integration spec at implementation time.

### Evidence A — the taint, and its real bounds

```
after first read on tenant pool (open_transactions)  => 1
status                                               => INTRANS
status after raw failing execute                     => INERROR   <- taint
open_transactions                                    => 1         <- AR did NOT roll back
status on re-entering same tenant                    => INERROR   <- survives switch exit
subsequent SELECT 1                                  => FAILED: PG::InFailedSqlTransaction
OTHER tenant's pool status                           => INTRANS   <- pool-per-tenant contains it
other tenant SELECT 1                                => SUCCEEDED
status after failure INSIDE transaction(requires_new)=> INTRANS   <- AR's savepoint heals
post-teardown pool acme:writing                      => IDLE      <- teardown heals
```

**Two findings constrain every candidate design.** Pool-per-tenant already contains the
blast radius to one tenant, and `transaction(requires_new: true)` already heals the
taint. The recovery primitive we might have invented is one Rails already ships.

### Evidence B — the savepoint regression is silent

The naive recovery: see `INERROR`, issue a raw `ROLLBACK`. Run it while an AR savepoint
stack is open:

```
open_transactions inside savepoint  => 2
status                              => INTRANS
status after raw ROLLBACK           => IDLE     <- the ENCLOSING transaction is gone
AR still believes open_transactions => 2        <- bookkeeping desynced
survived savepoint block exit       => yes      <- NO exception raised
WARNING:  there is no transaction in progress   <- the outer COMMIT hit nothing
```

**Nothing raises.** The enclosing transaction is destroyed, AR never notices, and the
outer `COMMIT` becomes a no-op. Under transactional fixtures this means the example's
fixture transaction is gone and every subsequent write **autocommits and leaks
permanently into the database**, which is precisely the order-dependent flake family
[`fixture-pool-lifecycle.md`](fixture-pool-lifecycle.md) exists to close.

**This is not hypothetical.** The best-effort `ROLLBACK` loop in the field is this
shape. Documenting the hazard is the highest-value output of this workstream: the
workaround is not merely unnecessary, it is a live source of the flakes it was written
to prevent.

### Evidence C — production taint is real, and AR's health check lies

```
status after manual begin_transaction + swallowed failure => INERROR
raw_connection.query(';') on tainted conn                 => SUCCEEDED  (active? => true)
conn.active?                                              => true
post-checkin pooled conn acme:writing                     => INERROR    <- back in the pool, tainted
post-checkin open_transactions                            => 1
next-request leased conn status                           => INERROR
next-request SELECT 1                                     => FAILED
```

**The mechanism is an empty query.** AR's `active?` runs `raw_connection.query(";")`,
and an empty query does *not* error in an aborted transaction. So `active?` returns
`true`, `verify!` pronounces a poisoned connection healthy, `checkin` does not reset
it, and the pool hands it to the next caller. Forever.

This refutes the "structurally test-only" reading that an earlier draft of this design
rested on. It does not, however, make recovery ours to ship. See
[The upstream Rails gap](#the-upstream-rails-gap).

## The v4 dividend

**v3 would have had this bug in its switch path; v4 does not.** v3 mutated
`search_path` on switch and restored it in an `ensure`. Against a tainted connection
that restore silently fails, because every statement raises. The tenant context would
then be *wrong* rather than merely broken, which is the class of bug this gem exists to
prevent.

chronomodel (see below) documents exactly that failure and works around it. **v4's
`switch` is a pure `Current.tenant` swap that executes no SQL**, so the tainted-ensure
failure mode is gone by construction, not by defense.

**Lock the property with a regression test.** "Switch's ensure issues no SQL" is now
load-bearing, and nothing currently asserts it.

## Prior art — what the ecosystem actually does

**No gem heals a poisoned pooled connection.** A GitHub code search for
`set_callback :checkin` combined with rollback returns zero results. What gems do with
`PQTRANS_INERROR` is uniformly *detect and avoid*:

- **[chronomodel](https://github.com/ifad/chronomodel)** — a PostgreSQL schema-switching
  gem, structurally the closest analogue to Apartment that exists. Its `on_schema`
  ensure block hits our exact problem, and its comment could have been written for us:

  > *"If the transaction is aborted, any `execute()` call will raise 'transaction is
  > aborted' errors, thus calling the Adapter's setter won't update the memoized
  > variable. Here we reset it to `nil` to refresh it on the next call, as there is no
  > way to know which path will be restored when the transaction ends."*

  It checks `INERROR` and **invalidates its cached state instead of executing
  anything**. It does not roll back. It does not heal.
- **[sequel-search-path](https://github.com/chanks/sequel-search-path)** — checks
  `INERROR` purely to *skip* setting the search path.
- **[pg-osc](https://github.com/shayonj/pg-osc)** — checks `INERROR` and bails out.

**Rails' own precedent points the same way.**
[rails/rails#12330](https://github.com/rails/rails/issues/12330) reported an analogous
poisoning: a failed `DEALLOCATE` inside an aborted transaction left a permanently broken
prepared-statement cache ("all old app servers are now permanently broken without a
restart"). Same shape, different cache. Rails fixed that one **in Rails**, not in a gem
downstream of it.

## What we ship

1. **Detection + instrumentation at the switch boundary.** In `Apartment::Tenant.switch`'s
   ensure, inspect *only an already-leased* connection for the tenant's pool: a
   `pool_manager` lookup plus `active_connection?`, so nothing is materialized and cold
   pools stay cold. On `INERROR`, emit `transaction_taint.apartment` (payload: `tenant:`,
   `pool_key:`) and `warn`. Add the event to the catalog in `docs/observability.md`.

2. **Never `raise` from the `ensure`.** A `raise` in an `ensure` block *replaces* the
   in-flight exception, so the original failure (the one that actually caused the taint)
   would be swallowed. Warn and instrument; do not raise. If a strict mode is ever wanted,
   it must raise only when `$!` is nil, and that is out of scope here.

3. **Integration spec that reproduces the taint for real.** Evidence A and B become
   `spec/integration/v4/transaction_taint_spec.rb`, driving the real fixture lifecycle.
   No mocking of `transaction_status`.

4. **Regression test for the v4 dividend.** Assert `switch`'s ensure issues no SQL, so a
   tainted connection can never corrupt tenant restoration.

5. **Docs.** `transaction(requires_new: true)` as the supported containment recipe (it is
   Rails' expression of psql's `ON_ERROR_ROLLBACK`, and Evidence A proves it heals), plus
   the raw-`ROLLBACK` hazard from Evidence B written up where a consumer will find it
   before they write the workaround.

6. **An upstream Rails issue** for the `active?` gap. See below.

**What the adopter deletes, and why.** Not because the gem mopped up: because the
instrumentation names the call site that taints, `requires_new` fixes it there, and the
`ROLLBACK` loop they have today is doing active harm (Evidence B).

## Never

Explicit rejections, recorded so they are not re-litigated.

1. **A raw `ROLLBACK` recovery, anywhere.** Evidence B: silently destroys the enclosing
   transaction, desyncs AR, raises nothing, converts a loud intra-example failure into
   permanent cross-example database pollution. This is the single most important
   rejection in this document, because it is what the field workaround does today.

2. **Savepoint containment inside `switch`.** Structurally unavailable, not merely
   costly. Issuing a `SAVEPOINT` requires a connection, and at switch *entry* the
   tenant's pool typically has none: `switch` is a `Current.tenant` swap and the block
   may never touch the database. Containment would force a connection checkout on every
   switch, materializing pools that lazy creation deliberately leaves cold and undoing
   the lazy-enrollment property established by the (a′) tiebreaker in
   [`fixture-pool-lifecycle.md`](fixture-pool-lifecycle.md).

3. **Deferred savepoint containment via AR's `checkout` callback.** Proposed during
   review as the fix for #2 (establish the savepoint at first checkout rather than at
   switch entry, preserving lazy pools). It fails in exactly the environment the taint
   lives in: `ConnectionPool#checkout` returns a pinned connection *directly*, never
   reaching `checkout_and_verify`, which is the only caller of `_run_checkout_callbacks`.
   **Under transactional fixtures the checkout callback never fires.**

4. **Healing at checkin (`conn.reset!` on `INERROR`, scoped to Apartment tenant pools).**
   The one *safe* heal: at checkin no caller holds the connection, so Evidence B's hazard
   cannot apply, and `reset!` is AR's own primitive (`ROLLBACK` + `DISCARD ALL` +
   `reset_transaction`). Rejected anyway, on three grounds. **No gem does this** and Rails
   does not either, so it is unprecedented surface on connections we did not poison. **The
   failure it prevents requires an app already doing something broken** (manual
   `begin_transaction`, raw `execute("BEGIN")`, a thread killed mid-rollback). **And it
   would paper over a Rails defect** we should instead report, leaving Apartment carrying a
   patch forever. Reconsider only on adopter-reported production evidence, which does not
   exist today. Code is a liability.

5. **Detecting by widening the predicate** (treating any non-`IDLE` status as taint, or
   probing connections the switch did not touch). This is what produced the savepoint
   regression in the field. The predicate stays narrow: `PQTRANS_INERROR`, on an
   already-leased connection, for the tenant being left.

## The upstream Rails gap

**A connection in a failed transaction passes ActiveRecord's health check and is served
to the next caller** (Evidence C). `active?` probes with `raw_connection.query(";")`; an
empty query does not error in an aborted transaction, so `verify!` reports the connection
healthy and `checkin` never resets it.

**No Rails issue exists for this.** The closest precedent, #12330, is the
prepared-statement variant of the same poisoning and was fixed in Rails.

**Action: open an issue against rails/rails** with the Evidence C reproduction. This is
not Apartment's to fix, and #4 in [Never](#never) records why we decline to.

## Open questions

- **Should the warning be rate-limited?** A tainted connection in a loop could warn on
  every switch. Probably warn-once-per-pool-per-taint; settle during implementation.
- **Does MySQL have an analogous state?** MySQL does not abort a transaction on statement
  error the way PostgreSQL does, so member 7 is expected to be PG-only. Confirm, and if so
  scope the detection to the PG adapters and say so in the docs rather than shipping a
  no-op on MySQL.

## Cross-references

- [`fixture-pool-lifecycle.md`](fixture-pool-lifecycle.md) — the failure class; member 7
  is this document. Members 1–5 closed; the (a′) lazy-enrollment result that Never #2
  depends on lives there.
- [`v4-beta-readiness.md`](v4-beta-readiness.md) — W1. Its "recovery path in `switch`'s
  ensure block" scope is superseded here.
- `docs/observability.md` — event catalog; `transaction_taint.apartment` is added there.
- `docs/testing.md` — where the `requires_new` containment recipe and the raw-`ROLLBACK`
  hazard belong.
- `lib/apartment/tenant.rb` — `switch` (the detection site).
- `lib/apartment/instrumentation.rb` — the `*.apartment` notification wrapper.

## Origin

2026-07-12. Scoped from `v4-beta-readiness.md` W1 as "instrumented detection + a recovery
path." Reproduction of the taint against a real fixture lifecycle, plus an adversarial
review panel, inverted the design: the recovery path is the dangerous half, the detection
is the valuable half, and the production reachability that the panel correctly forced into
the open turns out to be a Rails defect rather than a gem one. The panel's counter-proposal
(deferred savepoint containment at checkout) was itself refuted from ActiveRecord source
and is recorded as Never #3.
