# Transaction Taint: Detection and Checkin Heal (W1 / failure-class member 7)

Status: living. Design for `PQTRANS_INERROR` taint on tenant pools: where it is
detected, where it is healed, and the reasoned rejection of every other seam.
Supersedes the scope sketched for W1 in [`v4-beta-readiness.md`](v4-beta-readiness.md)
and for member 7 in [`fixture-pool-lifecycle.md`](fixture-pool-lifecycle.md); both
proposed "a recovery path in `Apartment::Tenant.switch`'s ensure block," which the
evidence below refutes twice over.

## Verdict

- **One hook, at connection checkin, on Apartment-owned tenant pools.** Detect
  `PQTRANS_INERROR`, instrument, warn, and heal with ActiveRecord's own `conn.reset!`.
  See [What we ship](#what-we-ship).
- **`switch` stays a pure `CurrentAttributes` swap.** It executes no SQL and checks out
  no connection. Detection there was the previous design and is now rejected: it cannot
  observe the production failure it was written to address. See [Never #5](#never).
- **The heal is proven safe, not argued safe.** `reset!` clears the failed state, resets
  AR's own transaction bookkeeping, **preserves the tenant's `search_path` through
  `DISCARD ALL`**, and cannot touch a fixture transaction because pinned connections
  never check in. Green on Rails 7.2 / 8.0 / 8.1. See [Evidence D](#evidence-d--the-heal-is-safe).
- **A raw `ROLLBACK` recovery must never ship, and it is what the field workaround does.**
  It silently destroys the enclosing transaction and leaks writes across examples. See
  [Evidence B](#evidence-b--the-savepoint-regression-is-silent).
- **PostgreSQL only.** MySQL fails the statement, not the transaction; there is no sticky
  aborted state and no `transaction_status` API. The predicate lives behind an adapter
  method. See [Evidence E](#evidence-e--mysql-has-no-analogous-state).
- **Rails' health check lies, and that stays a Rails bug we report.** We heal our own
  tenant pools; we do not patch the primary pool. See
  [The upstream Rails gap](#the-upstream-rails-gap).

## Contents

- [The mechanism](#the-mechanism)
- [Why the gem owns this](#why-the-gem-owns-this)
- [Evidence](#evidence)
- [What we ship](#what-we-ship)
- [The v4 dividend](#the-v4-dividend)
- [Never](#never)
- [The upstream Rails gap](#the-upstream-rails-gap)
- [Open decision](#open-decision)
- [Cross-references](#cross-references)

## The mechanism

**A PostgreSQL connection enters `PQTRANS_INERROR` when a statement fails inside a
transaction.** Every subsequent statement raises `PG::InFailedSqlTransaction` until the
transaction ends. That is PostgreSQL, not Rails and not Apartment.

**ActiveRecord heals this whenever the failing statement is inside an AR transaction
block**, because the `TransactionManager` unwinds via `ROLLBACK` or
`ROLLBACK TO SAVEPOINT`. A failure inside `transaction(requires_new: true)` leaves the
connection `INTRANS` and fully usable (Evidence A).

**The taint survives only in the gap:** a statement AR did not wrap, failing while a
transaction AR will not unwind stays open. Two populations land there.

| | Fixture pool (pinned) | Production pool |
|---|---|---|
| Who holds the transaction open | the fixture transaction | app code: `begin_transaction` without a block, raw `execute("BEGIN")`, a thread killed mid-rollback |
| Does AR heal it? | at teardown, yes | **never** |
| Outlives the example / request? | no | **yes, indefinitely** |
| Does `checkin` fire? | no (pinned connections skip it) | yes, but AR does not reset on checkin |
| Blast radius | rest of the example, one tenant | that tenant, on that worker, until process restart |

**The two populations want opposite things**, which is why one seam serves both. The
fixture connection must keep its transaction (teardown owns the rollback). The production
connection must be reset before reuse. Checkin distinguishes them for free: pinned
connections never reach it.

## Why the gem owns this

**The taint mechanism is generic Rails/PG. The consequence is specific to us.** In a
shared Rails pool a poisoned connection is one of N, and the app limps on. Under
pool-per-tenant it is the *only* connection for that tenant, so the production failure
reads as: **one tenant is dead on one worker, every other tenant is fine, and nothing in
the logs explains why.**

**That is why "no other gem does this" is weak evidence.** chronomodel,
sequel-search-path, and pg-osc detect `INERROR` and avoid, and none of them heal — but
none of them own pools either. They are schema-switching gems, not connection-lifecycle
managers. The comparison set cannot have our failure, so its silence is not a verdict.
Rails does not heal because Rails does not need to as badly; and Rails' actual precedent
([#12330](https://github.com/rails/rails/issues/12330), a prepared-statement poisoning
that permanently bricked app servers) is that **the layer owning the poisoned cache fixes
it.** Apartment owns the tenant pools.

## Evidence

Reproduced against PostgreSQL 18, driving the real `setup_fixtures` /
`teardown_fixtures` lifecycle. Not mocked. These probes become the integration spec.

### Evidence A — the taint, and its real bounds

```
status after raw failing execute                     => INERROR   <- taint
open_transactions                                    => 1         <- AR did NOT roll back
status on re-entering same tenant                    => INERROR   <- survives switch exit
subsequent SELECT 1                                  => FAILED: PG::InFailedSqlTransaction
OTHER tenant's pool status                           => INTRANS   <- pool-per-tenant contains it
status after failure INSIDE transaction(requires_new)=> INTRANS   <- AR's savepoint heals
post-teardown pool acme:writing                      => IDLE      <- teardown heals
```

**Two findings constrain every design.** Pool-per-tenant already contains the blast radius
to one tenant, and `transaction(requires_new: true)` already heals the taint: the
containment primitive we might have invented is one Rails ships (it is Rails' expression of
psql's `ON_ERROR_ROLLBACK`).

### Evidence B — the savepoint regression is silent

The naive recovery, run while an AR savepoint stack is open:

```
open_transactions inside savepoint  => 2
status after raw ROLLBACK           => IDLE     <- the ENCLOSING transaction is gone
AR still believes open_transactions => 2        <- bookkeeping desynced
survived savepoint block exit       => yes      <- NO exception raised
WARNING:  there is no transaction in progress   <- the outer COMMIT hit nothing
```

**Nothing raises.** Under transactional fixtures the example's fixture transaction is
destroyed and every subsequent write **autocommits and leaks permanently into the
database**, which is exactly the order-dependent flake family
[`fixture-pool-lifecycle.md`](fixture-pool-lifecycle.md) exists to close.

**The best-effort `ROLLBACK` loop seen in the field is this shape.** Documenting the hazard
is independently worth the workstream: that workaround is not merely unnecessary, it is a
live source of the flakes it was written to prevent.

### Evidence C — production taint is real, and AR's health check lies

```
status after manual begin_transaction + swallowed failure => INERROR
raw_connection.query(';') on tainted conn                 => SUCCEEDED (active? => true)
post-checkin pooled conn acme:writing                     => INERROR   <- back in the pool, tainted
next-request leased conn status                           => INERROR
next-request SELECT 1                                     => FAILED
```

**The mechanism is an empty query.** AR's `active?` probes with
`raw_connection.query(";")`, and an empty query does not error in an aborted transaction.
So `active?` returns `true`, `verify!` pronounces a poisoned connection healthy, `checkin`
does not reset it, and the pool serves it to the next caller. Indefinitely.

### Evidence D — the heal is safe

`conn.reset!` at checkin, on a poisoned tenant connection. **Green on Rails 7.2, 8.0, and
8.1.**

```
A. status after poison                       => INERROR
A. open_transactions after poison            => 1
A. status after reset!                       => IDLE
A. open_transactions after reset!            => 0        <- AR's bookkeeping reset too, no desync
B. search_path BEFORE poison                 => acme_799e0c26
B. search_path AFTER reset! (DISCARD ALL)    => acme_799e0c26
B. SEARCH_PATH PRESERVED?                    => YES      <- no cross-tenant leak
B. current_schema() after heal               => acme_799e0c26
D. pinned? (under fixtures)                  => true
D. heals fired (must be [])                  => []       <- pinned connection SKIPPED
D. open_transactions (fixture tx intact?)    => 1        <- fixture transaction untouched
E. poison -> checkin -> next-request query    => SUCCEEDED -- POOL HEALED
```

**Check B was the make-or-break.** `reset!` issues `DISCARD ALL`, which resets session
state. Had it dropped the tenant's `search_path`, healing a connection would silently
repoint it at the `public` schema, turning a bricked tenant into a **cross-tenant data
leak** — a catastrophically worse bug than the one being fixed. It does not:
`attempt_configure_connection` re-applies `schema_search_path` from the pool's connection
config. Verified by `SHOW search_path` and `current_schema()` on both sides of the reset.

**Check D is why one seam serves both populations.** Fixture-pinned connections never
reach `checkin` (`ConnectionPool#checkin` returns early for `@pinned_connection`), so the
heal is structurally incapable of touching a fixture transaction. Evidence B's hazard
cannot apply at checkin either: no caller holds the connection, so there is no enclosing
transaction to destroy.

### Evidence E — MySQL has no analogous state

```
adapter                                        => Mysql2
raw_connection responds to transaction_status? => false      <- no such API
INSERT after failed statement                  => SUCCEEDED -- no sticky abort state
SELECT after failed statement                  => SUCCEEDED (count=2)
rows after rollback                            => 0          <- transaction intact throughout
```

**MySQL fails the statement, not the transaction.** Member 7 is PostgreSQL-only. The
predicate therefore lives behind an adapter method, defaulting to `false`, implemented on
the PG adapters — not as an engine-agnostic check that would be dead code on MySQL and
SQLite.

## What we ship

1. **A pool-scoped checkin heal.** Apartment extends a module onto the tenant pools it
   creates (`PoolManager`), overriding `ConnectionPool#checkin`. Before delegating: if the
   adapter reports an aborted transaction and the connection is **not pinned**, instrument,
   warn, and call `conn.reset!`. Scoped by construction to pools Apartment owns; the
   primary pool and every app pool are untouched. No global adapter patch.

2. **An adapter predicate.** `aborted_transaction?(conn)` on `AbstractAdapter` returning
   `false`; the PostgreSQL adapters check
   `raw_connection.transaction_status == PG::PQTRANS_INERROR`. Evidence E is the reason
   this is not inlined.

3. **Instrumentation.** `transaction_taint.apartment` (payload: `tenant:`, `pool_key:`,
   `open_transactions:`, `healed:`), added to the catalog in `docs/observability.md`. The
   heal fixes the pool; the event preserves the signal that app code is wrong. **Both, not
   either** — a silent heal would paper over the adopter's bug, which is the one fair
   criticism of healing.

4. **Rate-limited warning.** Warn-once-per-pool-per-taint. Not polish: a poisoned pool in a
   `Tenant.each` fan-out would otherwise emit N warnings during the exact incident where
   the signal matters.

5. **Integration spec.** Evidence A–E become `spec/integration/v4/transaction_taint_spec.rb`,
   driving the real fixture lifecycle. No mocking of `transaction_status`. Must include the
   negative cases: the pinned connection is skipped, and the fixture transaction survives.

6. **Regression test for the v4 dividend** (below).

7. **Docs.** `transaction(requires_new: true)` as the containment recipe, and the
   raw-`ROLLBACK` hazard from Evidence B written where a consumer finds it *before* they
   write the workaround.

8. **An upstream Rails issue** for the `active?` gap.

**What the adopter gets, stated honestly.** Their `ROLLBACK` loop goes away and is not
replaced by a warning: the pool heals itself at checkin. The instrumentation still names
the tainting tenant so they can fix the call site with `requires_new`. And Evidence B tells
them the loop they have today is actively harmful, which is true whether or not they adopt
anything else here.

## The v4 dividend

**v3 would have had this bug in its switch path; v4 does not.** v3 mutated `search_path` on
switch and restored it in an `ensure`. Against a tainted connection that restore silently
fails, leaving the tenant context *wrong* rather than merely broken.

chronomodel documents exactly this and works around it: its `on_schema` ensure block checks
`INERROR` and invalidates its memoized search path rather than trying to restore it,
because "there is no way to know which path will be restored when the transaction ends."
**v4's `switch` executes no SQL**, so the failure mode is gone by construction rather than
by defense. Nothing currently asserts that property, and it is now load-bearing: lock it
with a regression test.

## Never

Explicit rejections, recorded so they are not re-litigated.

1. **A raw `ROLLBACK` recovery, anywhere.** Evidence B: silently destroys the enclosing
   transaction, desyncs AR, raises nothing, converts a loud intra-example failure into
   permanent cross-example database pollution. Distinct from `reset!` (Evidence D), which is
   AR's own primitive and resets AR's bookkeeping along with the connection. Conflating the
   two was an error in the previous draft of this document.

2. **Savepoint containment at switch entry.** A `SAVEPOINT` requires a connection, and at
   switch entry the tenant's pool typically has none: `switch` is a `Current.tenant` swap and
   the block may never touch the database. Containment would force a checkout on every
   switch, materializing pools that lazy creation deliberately leaves cold and undoing the
   lazy-enrollment property established by the (a′) tiebreaker in
   [`fixture-pool-lifecycle.md`](fixture-pool-lifecycle.md).

3. **Deferred savepoint containment via AR's `checkout` callback.** The obvious fix for #2
   (establish the savepoint at first checkout, preserving lazy pools). It fails in exactly
   the environment the taint lives in: `ConnectionPool#checkout` returns a pinned connection
   *directly*, never reaching `checkout_and_verify`, the only caller of
   `_run_checkout_callbacks`. **Under transactional fixtures the checkout callback never
   fires.**

4. **Healing the primary / default pool.** The same defect poisons any Rails pool, but the
   primary is not ours and the blast radius there is one connection of N, not a dead tenant.
   Patching it would make Apartment a permanent workaround for a Rails bug on connections it
   did not create. Report upstream instead.

5. **Detection at the switch boundary.** This was the previous design, and it is wrong on
   four counts. It **cannot see the production failure**: by the time a request's `switch`
   ensure runs, the poisoned connection's fate is decided at checkin, and detecting it there
   names a landmine without removing it. It **misses `switch!`, `reset`, and `each`**, which
   have no block boundary. It **couples a pure context swap to pool internals**
   (`pool_manager` lookup, lease probe, adapter `transaction_status`), soiling the very v4
   dividend this document celebrates. And a `PoolManager#get` on every switch exit would
   **distort the reaper's LRU timestamps**. Checkin is strictly better on all four.

6. **Raising from the `ensure` block.** A `raise` in `ensure` replaces the in-flight
   exception (attaching the original only as `#cause`), so the failure that *caused* the
   taint would be masked behind a report *about* the taint. Moot under the checkin design,
   recorded because the previous draft proposed the seam.

## The upstream Rails gap

**A connection in a failed transaction passes ActiveRecord's health check and is served to
the next caller** (Evidence C). `active?` probes with `raw_connection.query(";")`; an empty
query does not error in an aborted transaction, so `verify!` reports the connection healthy
and `checkin` never resets it.

**No Rails issue exists for this.** The closest precedent, #12330, is the prepared-statement
variant of the same poisoning, and it was fixed in Rails.

**Action: open an issue against rails/rails** with the Evidence C reproduction. Our checkin
heal covers Apartment's tenant pools; it deliberately does not cover the primary pool
(Never #4), so the upstream fix still matters and we should not let shipping ours reduce the
pressure for it.

## Known consequences (accepted, not defects)

Surfaced by adversarial review of the implementation. Each is a real property of the
design; none changes the verdict, and each is cheaper than the outage it replaces.

**`DISCARD ALL` destroys session state beyond the transaction.** `reset!` drops prepared
statements, temp tables, `LISTEN` registrations, session GUCs, `SET ROLE`/session
authorization, and session-level advisory locks. Only `schema_search_path` is restored (by
`attempt_configure_connection` — Evidence D, and the guard test that proves it). This is
acceptable because **the connection we are resetting cannot execute any statement at all**:
a poisoned session is not safely reusable, so there is no state on it worth preserving. AR
reaches the same conclusion — `reset!` is what its own `reap` and `unpin_connection!` call.
Adopters holding session advisory locks (migrations do) are unaffected: those run on a
connection that is not in `PQTRANS_INERROR`, or they have already failed.

**Only `PQTRANS_INERROR` is healed.** `PQTRANS_UNKNOWN` means the connection itself is
broken, not that its transaction is aborted — a real query fails against it, so AR's own
`active?`/`verify!`/`reconnect!` path reclaims it correctly. That case needs no help from
us, and widening the predicate to cover it would re-introduce exactly the over-broad-match
error that produced the adopter's savepoint regression. `PQTRANS_INTRANS` (an open but
healthy transaction) is likewise never healed — there is a test for it.

**The heal fires at checkin, not at checkout.** A connection poisoned mid-request stays
poisoned for the rest of *that* request; we cannot reset it without destroying a transaction
the application still owns. Recovery is guaranteed for the *next* lease, which is the
property that keeps the tenant alive. If `reset!` itself fails, the connection is
disconnected rather than re-pooled, so the next checkout reconnects fresh — the one path
that would otherwise rebuild the original outage.

**The default tenant's pool is not healed.** It is the primary ActiveRecord pool, not one
Apartment creates (Never #4). Adopters who serve real traffic from `default_tenant` keep the
stock Rails exposure there. Healing it would mean patching the main pool of every Rails app
that loads this gem — a much larger claim than the one this design makes, and the reason the
upstream issue below still matters.

## Decisions (settled)

**The heal is default-on** (`heal_tainted_connections`, disableable). Off-by-default would
make the outage the default experience, and a knob named "don't brick my tenant" is a strange
thing to make an adopter discover. Evidence D is green across the matrix, the heal cannot
reach a fixture transaction, and on a healthy connection it is a status read and nothing
more. The conservative alternative — opt-in, flagged experimental for the beta — was argued
in review and rejected on those grounds.

**Scope stays as written**: Apartment's tenant pools, PostgreSQL, checkin. Review pushed to
widen it to the default tenant's pool; declined, because that is the primary ActiveRecord
pool and healing it means patching the main pool of every Rails app that loads this gem — a
much larger claim than this design makes. That exposure is real, it is stock Rails, and it is
what the upstream issue below exists to close.

## Cross-references

- [`fixture-pool-lifecycle.md`](fixture-pool-lifecycle.md) — the failure class; member 7 is
  this document. The (a′) lazy-enrollment result that Never #2 depends on lives there.
- [`v4-beta-readiness.md`](v4-beta-readiness.md) — W1. Its "recovery path in `switch`'s
  ensure block" scope is superseded here.
- `docs/observability.md` — event catalog; `transaction_taint.apartment` is added there.
- `docs/testing.md` — the `requires_new` containment recipe and the raw-`ROLLBACK` hazard.
- `lib/apartment/pool_manager.rb` — creates the tenant pools the heal is scoped to.
- `lib/apartment/adapters/abstract_adapter.rb` — home of the `aborted_transaction?` predicate.
- `lib/apartment/tenant.rb` — `switch`, which this design deliberately leaves untouched.

## Origin

2026-07-12. Scoped from `v4-beta-readiness.md` W1 as "instrumented detection + a recovery
path in switch's ensure." Reproduction against a real fixture lifecycle inverted it twice.
First: the recovery path, as written in the field, is the dangerous half (Evidence B), and an
early draft concluded the taint was test-only and shipped detection alone. An adversarial
panel refuted that — production poisoning is real (Evidence C), and the detector was placed
where it structurally could not observe the failure it was written for. The panel also named
the argument the first draft leaned on: "no gem heals a pooled connection" is an argument
from absence, and the absence is explained by the fact that no comparable gem owns pools.
The heal was then proven rather than argued (Evidence D), and the engine scope measured
rather than assumed (Evidence E).
