# W1 — Transaction Taint: Checkin Detection + Heal — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Heal PostgreSQL connections left in `PQTRANS_INERROR` when they are checked back into an Apartment-owned tenant pool, so a poisoned connection can never be served to the next caller and brick a tenant.

**Architecture:** One seam. Apartment extends a module onto the tenant pools it creates, overriding `ConnectionPool#checkin`. Before delegating to `super`, if the adapter reports an aborted transaction and the connection is **not pinned**, we instrument, warn once, and call ActiveRecord's own `conn.reset!`. `Apartment::Tenant.switch` is not touched and stays a pure `CurrentAttributes` swap. Fixture-pinned connections never reach `checkin`, so the heal is structurally incapable of touching a fixture transaction.

**Tech Stack:** Ruby, ActiveRecord 7.2/8.0/8.1, PostgreSQL (pg gem), RSpec, Zeitwerk, RuboCop.

**Design doc:** [`docs/designs/transaction-taint-detection.md`](../../designs/transaction-taint-detection.md). Read it before starting — every rejection in its "Never" section is load-bearing, and Evidence B explains why a raw `ROLLBACK` must never appear in this code.

## Global Constraints

- **OSS gem.** Never reference CampusESP, `www`, or any private repo/path/PR in code, comments, docs, commit messages, or the PR body. The downstream consumer is "the primary adopter."
- **PostgreSQL only.** MySQL fails the statement, not the transaction (Evidence E: `raw_connection` has no `transaction_status` at all). The predicate lives behind an adapter method defaulting to `false`. No engine-agnostic taint code.
- **Never issue a raw `ROLLBACK`.** Evidence B: it silently destroys the enclosing transaction and desyncs AR. `conn.reset!` is the only sanctioned heal — it resets AR's transaction bookkeeping along with the connection.
- **Never raise out of `checkin`.** A raise there would break connection return and leak the pool. All heal logic is rescued.
- **`Apartment::Tenant.switch` must not change.** Its SQL-free ensure block is the v4 dividend; Task 7 locks it with a regression test.
- **Zeitwerk autoloads `lib/apartment/**`.** New files need no `require`; name them so the path matches the constant.
- **RuboCop on ALL changed files (impl + specs) before every push:** `bundle exec rubocop <files>`.
- **Commit after each task.** Feature branch `design/w1-transaction-taint-detection` (already exists, off `main`). Squash-merge; do not self-approve.

---

## File Structure

**Create:**
- `lib/apartment/adapters/postgresql_transaction_state.rb` — shared PG predicate module, included by both PG adapters (their bodies are identical, so this is the DRY seam).
- `lib/apartment/transaction_taint.rb` — `Apartment::TransactionTaint`: the `PoolHeal` module extended onto tenant pools, plus the heal logic.
- `spec/unit/transaction_taint_spec.rb` — unit coverage with doubles (no DB).
- `spec/integration/v4/transaction_taint_spec.rb` — the real reproduction (Evidence A–E).
- `docs/rails-upstream-active-verify-gap.md` — drafted text for the upstream Rails issue (Task 9 does not file it).

**Modify:**
- `lib/apartment/adapters/abstract_adapter.rb` — add `aborted_transaction?(_conn) => false`.
- `lib/apartment/adapters/postgresql_schema_adapter.rb` — `include PostgresqlTransactionState`.
- `lib/apartment/adapters/postgresql_database_adapter.rb` — `include PostgresqlTransactionState`.
- `lib/apartment/config.rb` — add `heal_tainted_connections` (default `true`) + boolean validation.
- `lib/apartment/patches/connection_handling.rb` — install the healer on each newly created tenant pool.
- `spec/unit/tenant_spec.rb` — regression test: `switch`'s ensure issues no SQL.
- `docs/observability.md` — add `transaction_taint.apartment` to the event catalog.
- `docs/testing.md` — the `requires_new` containment recipe and the raw-`ROLLBACK` hazard.
- `docs/designs/fixture-pool-lifecycle.md` — member 7 row + Wishlist entry now point at the shipped design.
- `docs/designs/v4-beta-readiness.md` — W1 scope corrected (this is the #471 reconciliation; see Task 10).

---

### Task 1: Adapter predicate — `aborted_transaction?`

The engine seam. Base returns `false`; the two PostgreSQL adapters share one implementation. Follows the existing `shared_pinned_connection?` / `container_error?` convention in this codebase.

**Files:**
- Create: `lib/apartment/adapters/postgresql_transaction_state.rb`
- Modify: `lib/apartment/adapters/abstract_adapter.rb` (add method next to `shared_pinned_connection?`, ~line 117)
- Modify: `lib/apartment/adapters/postgresql_schema_adapter.rb` (add `include` after `class` line ~14)
- Modify: `lib/apartment/adapters/postgresql_database_adapter.rb` (add `include` after `class` line ~12)
- Test: `spec/unit/transaction_taint_spec.rb` (create)

**Interfaces:**
- Produces: `AbstractAdapter#aborted_transaction?(conn) -> Boolean`. Every adapter answers it. Only the PG adapters can return `true`.

- [ ] **Step 1: Write the failing test**

Create `spec/unit/transaction_taint_spec.rb`:

```ruby
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe('transaction taint') do
  describe 'Apartment::Adapters::AbstractAdapter#aborted_transaction?' do
    let(:adapter) { Apartment::Adapters::AbstractAdapter.new({}) }
    let(:conn)    { instance_double(ActiveRecord::ConnectionAdapters::AbstractAdapter) }

    it 'is false by default — only PostgreSQL has a sticky aborted-transaction state' do
      expect(adapter.aborted_transaction?(conn)).to be(false)
    end
  end

  describe Apartment::Adapters::PostgresqlTransactionState do
    let(:adapter) do
      Class.new(Apartment::Adapters::AbstractAdapter) do
        include Apartment::Adapters::PostgresqlTransactionState
      end.new({})
    end

    def conn_with(status)
      raw = double('PG::Connection', transaction_status: status) # rubocop:disable RSpec/VerifiedDoubles
      instance_double(ActiveRecord::ConnectionAdapters::AbstractAdapter, raw_connection: raw)
    end

    it 'is true when the raw connection reports PQTRANS_INERROR' do
      expect(adapter.aborted_transaction?(conn_with(PG::PQTRANS_INERROR))).to be(true)
    end

    it 'is false for a healthy in-transaction connection' do
      expect(adapter.aborted_transaction?(conn_with(PG::PQTRANS_INTRANS))).to be(false)
    end

    it 'is false for an idle connection' do
      expect(adapter.aborted_transaction?(conn_with(PG::PQTRANS_IDLE))).to be(false)
    end

    it 'is false when the connection has no raw connection yet' do
      conn = instance_double(ActiveRecord::ConnectionAdapters::AbstractAdapter, raw_connection: nil)
      expect(adapter.aborted_transaction?(conn)).to be(false)
    end

    it 'is false — never raises — when the raw connection cannot answer' do
      raw  = Object.new # does not respond to transaction_status
      conn = instance_double(ActiveRecord::ConnectionAdapters::AbstractAdapter, raw_connection: raw)
      expect(adapter.aborted_transaction?(conn)).to be(false)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/unit/transaction_taint_spec.rb`
Expected: FAIL — `uninitialized constant Apartment::Adapters::PostgresqlTransactionState` and `undefined method 'aborted_transaction?'`.

- [ ] **Step 3: Add the base predicate**

In `lib/apartment/adapters/abstract_adapter.rb`, immediately after `shared_pinned_connection?` (which ends ~line 119):

```ruby
      # Whether +conn+ sits in an aborted-transaction state that every subsequent
      # statement will fail against until the transaction ends. PostgreSQL is the
      # only supported engine with such a state (PQTRANS_INERROR); MySQL fails the
      # statement and leaves the transaction usable, and its raw connection has no
      # transaction_status at all. Base is conservative: never reclassify.
      # See docs/designs/transaction-taint-detection.md (Evidence E).
      def aborted_transaction?(_conn)
        false
      end
```

- [ ] **Step 4: Create the shared PostgreSQL module**

Create `lib/apartment/adapters/postgresql_transaction_state.rb`:

```ruby
# frozen_string_literal: true

module Apartment
  module Adapters
    # PostgreSQL's aborted-transaction state, shared by both PG adapters
    # (schema-per-tenant and database-per-tenant). Their implementations are
    # identical, so this is the DRY seam rather than two copies.
    #
    # A failed statement inside a transaction moves the connection to
    # PQTRANS_INERROR, where every subsequent statement raises
    # PG::InFailedSqlTransaction until the transaction ends. Apartment heals this
    # at pool checkin; see docs/designs/transaction-taint-detection.md.
    module PostgresqlTransactionState
      def aborted_transaction?(conn)
        raw = conn.raw_connection
        return false unless raw.respond_to?(:transaction_status)

        raw.transaction_status == ::PG::PQTRANS_INERROR
      rescue StandardError
        # A connection too broken to report its own status is not our business to
        # classify; AR's own verify!/reconnect path owns that case.
        false
      end
    end
  end
end
```

- [ ] **Step 5: Include it in both PostgreSQL adapters**

In `lib/apartment/adapters/postgresql_schema_adapter.rb`, directly under `class PostgresqlSchemaAdapter < AbstractAdapter`:

```ruby
      include PostgresqlTransactionState
```

In `lib/apartment/adapters/postgresql_database_adapter.rb`, directly under `class PostgresqlDatabaseAdapter < AbstractAdapter`:

```ruby
      include PostgresqlTransactionState
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `bundle exec rspec spec/unit/transaction_taint_spec.rb`
Expected: PASS (5 examples).

Then confirm nothing else broke: `bundle exec rspec spec/unit/`
Expected: PASS.

- [ ] **Step 7: RuboCop and commit**

```bash
bundle exec rubocop lib/apartment/adapters/postgresql_transaction_state.rb \
  lib/apartment/adapters/abstract_adapter.rb \
  lib/apartment/adapters/postgresql_schema_adapter.rb \
  lib/apartment/adapters/postgresql_database_adapter.rb \
  spec/unit/transaction_taint_spec.rb
git add lib/apartment/adapters spec/unit/transaction_taint_spec.rb
git commit -m "Feat(v4): aborted_transaction? adapter predicate (PG-only, per Evidence E)"
```

---

### Task 2: Config option — `heal_tainted_connections`

**Files:**
- Modify: `lib/apartment/config.rb` (attr_accessor list ~line 30; default in `initialize` ~line 65; validation near the `reap_in_test` check ~line 256)
- Test: `spec/unit/config_spec.rb`

**Interfaces:**
- Produces: `Apartment.config.heal_tainted_connections -> Boolean` (default `true`).

**Note on the default.** The design doc's [Open decision](../../designs/transaction-taint-detection.md#open-decision) recommends default-on with an escape hatch, which is what this task implements. If the maintainer chooses opt-in instead, this is a one-line change (`@heal_tainted_connections = false`) plus the doc wording; nothing else in the plan moves.

- [ ] **Step 1: Write the failing test**

Append to `spec/unit/config_spec.rb`:

```ruby
  describe 'heal_tainted_connections' do
    it 'defaults to true — a poisoned tenant connection is healed at checkin' do
      Apartment.configure { |c| c.default_tenant = 'public' }
      expect(Apartment.config.heal_tainted_connections).to be(true)
    end

    it 'can be disabled' do
      Apartment.configure do |c|
        c.default_tenant = 'public'
        c.heal_tainted_connections = false
      end
      expect(Apartment.config.heal_tainted_connections).to be(false)
    end

    it 'rejects a non-boolean' do
      expect do
        Apartment.configure do |c|
          c.default_tenant = 'public'
          c.heal_tainted_connections = 'yes'
        end
      end.to raise_error(Apartment::ConfigurationError, /heal_tainted_connections must be true or false/)
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/unit/config_spec.rb -e heal_tainted_connections`
Expected: FAIL — `undefined method 'heal_tainted_connections'`.

- [ ] **Step 3: Add the option**

In `lib/apartment/config.rb`, extend the `attr_accessor` list (the line currently ending `:reap_in_test`):

```ruby
                  :force_separate_pinned_pool, :test_fixture_cleanup, :reap_in_test,
                  :heal_tainted_connections
```

In `initialize`, next to `@reap_in_test = false`:

```ruby
      # Heal a tenant connection left in an aborted transaction when it is checked
      # back into its pool. On by default: without it, a poisoned connection is
      # served to the next caller and that tenant is dead on that worker until the
      # process restarts (AR's active? does not detect the state). PostgreSQL-only
      # in effect. See docs/designs/transaction-taint-detection.md.
      @heal_tainted_connections = true
```

In `validate!`, next to the `reap_in_test` check:

```ruby
      unless [true, false].include?(@heal_tainted_connections)
        raise(ConfigurationError,
              'heal_tainted_connections must be true or false, ' \
              "got: #{@heal_tainted_connections.inspect}")
      end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/unit/config_spec.rb`
Expected: PASS.

- [ ] **Step 5: RuboCop and commit**

```bash
bundle exec rubocop lib/apartment/config.rb spec/unit/config_spec.rb
git add lib/apartment/config.rb spec/unit/config_spec.rb
git commit -m "Feat(v4): heal_tainted_connections config option (default true)"
```

---

### Task 3: `Apartment::TransactionTaint` — the heal

The core. A module extended onto tenant pools that intercepts `checkin`.

**Files:**
- Create: `lib/apartment/transaction_taint.rb`
- Test: `spec/unit/transaction_taint_spec.rb` (append)

**Interfaces:**
- Consumes: `AbstractAdapter#aborted_transaction?(conn)` (Task 1); `Apartment.config.heal_tainted_connections` (Task 2); `Apartment::Instrumentation.instrument(event, payload)`.
- Produces:
  - `Apartment::TransactionTaint.install(pool, tenant:, pool_key:) -> pool` — extends `PoolHeal` onto the pool and stamps it with the tenant/pool_key used in the event payload. No-op (returns the pool unchanged) when the config flag is off.
  - `Apartment::TransactionTaint::PoolHeal#checkin(conn)` — heals, then `super`.
  - Emits `transaction_taint.apartment` with payload `{ tenant:, pool_key:, open_transactions:, healed: }`.

**Three invariants this code must not violate** (each has a test below):
1. **Pinned connections are skipped.** A fixture-pinned connection's transaction belongs to `teardown_fixtures`. `ConnectionPool#checkin` returns early for the pinned connection, but our override runs *before* `super`, so we must check `conn.pinned` ourselves.
2. **Nothing raises out of `checkin`.** A raise would break connection return and leak the pool.
3. **`reset!` only. Never a raw `ROLLBACK`.** See Evidence B.

- [ ] **Step 1: Write the failing tests**

Append to `spec/unit/transaction_taint_spec.rb`:

```ruby
RSpec.describe(Apartment::TransactionTaint) do
  # A minimal stand-in for ActiveRecord's ConnectionPool: `checkin` records the
  # call and does nothing else, so `super` is observable.
  let(:pool_class) do
    Class.new do
      attr_reader :checked_in

      def initialize = @checked_in = []
      def checkin(conn) = @checked_in << conn
    end
  end

  let(:pool)    { pool_class.new }
  let(:adapter) { instance_double(Apartment::Adapters::AbstractAdapter) }

  def connection(aborted:, pinned: false, open_transactions: 1)
    conn = instance_double(
      ActiveRecord::ConnectionAdapters::AbstractAdapter,
      pinned: pinned,
      open_transactions: open_transactions
    )
    allow(conn).to receive(:reset!)
    allow(adapter).to receive(:aborted_transaction?).with(conn).and_return(aborted)
    conn
  end

  before do
    Apartment.configure { |c| c.default_tenant = 'public' }
    allow(Apartment).to receive(:adapter).and_return(adapter)
    described_class.install(pool, tenant: 'acme', pool_key: 'acme:writing')
  end

  it 'resets a connection left in an aborted transaction' do
    conn = connection(aborted: true)
    pool.checkin(conn)
    expect(conn).to have_received(:reset!)
  end

  it 'still checks the connection in after healing it' do
    conn = connection(aborted: true)
    pool.checkin(conn)
    expect(pool.checked_in).to eq([conn])
  end

  it 'leaves a healthy connection alone' do
    conn = connection(aborted: false)
    pool.checkin(conn)
    expect(conn).not_to have_received(:reset!)
  end

  it 'SKIPS a fixture-pinned connection — its transaction belongs to teardown_fixtures' do
    conn = connection(aborted: true, pinned: true)
    pool.checkin(conn)
    expect(conn).not_to have_received(:reset!)
  end

  it 'emits transaction_taint.apartment naming the tenant' do
    conn = connection(aborted: true, open_transactions: 2)
    events = []
    ActiveSupport::Notifications.subscribed(->(*, payload) { events << payload },
                                            'transaction_taint.apartment') do
      pool.checkin(conn)
    end
    expect(events.first).to include(
      tenant: 'acme', pool_key: 'acme:writing', open_transactions: 2, healed: true
    )
  end

  it 'never raises out of checkin, even when reset! blows up' do
    conn = connection(aborted: true)
    allow(conn).to receive(:reset!).and_raise(StandardError, 'boom')
    expect { pool.checkin(conn) }.not_to raise_error
  end

  it 'still checks the connection in when the heal itself failed' do
    conn = connection(aborted: true)
    allow(conn).to receive(:reset!).and_raise(StandardError, 'boom')
    pool.checkin(conn)
    expect(pool.checked_in).to eq([conn])
  end

  it 'does not extend the pool at all when heal_tainted_connections is false' do
    Apartment.configure do |c|
      c.default_tenant = 'public'
      c.heal_tainted_connections = false
    end
    plain = pool_class.new
    described_class.install(plain, tenant: 'acme', pool_key: 'acme:writing')
    expect(plain).not_to be_a(described_class::PoolHeal)
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/unit/transaction_taint_spec.rb`
Expected: FAIL — `uninitialized constant Apartment::TransactionTaint`.

- [ ] **Step 3: Write the implementation**

Create `lib/apartment/transaction_taint.rb`:

```ruby
# frozen_string_literal: true

module Apartment
  # Heals a tenant connection left in an aborted transaction (PostgreSQL's
  # PQTRANS_INERROR) at the moment it is checked back into its pool.
  #
  # WHY CHECKIN. ActiveRecord's active? probes with an empty query, which does NOT
  # error in an aborted transaction, so verify! pronounces a poisoned connection
  # healthy and checkin does not reset it. The pool then serves it to the next
  # caller. Under pool-per-tenant that connection is the ONLY connection for its
  # tenant, so the tenant is dead on that worker until the process restarts, while
  # every other tenant looks fine.
  #
  # Checkin is also the one seam that serves both populations correctly: a
  # FIXTURE-PINNED connection must KEEP its transaction (teardown_fixtures owns the
  # rollback) and never reaches checkin, while a production connection must be reset
  # before reuse. We still check `pinned` explicitly because this override runs
  # before ConnectionPool#checkin's own early return.
  #
  # NEVER issue a raw ROLLBACK here. It destroys the ENCLOSING transaction while AR
  # still believes its stack is intact, raises nothing, and lets subsequent writes
  # autocommit. `reset!` is AR's own primitive: it rolls back, DISCARDs session
  # state, and resets AR's transaction bookkeeping together. It also re-applies the
  # pool's schema_search_path, so a healed tenant connection still points at its own
  # schema (verified — the alternative would be a cross-tenant leak).
  #
  # Design: docs/designs/transaction-taint-detection.md
  module TransactionTaint
    # Extended onto Apartment-owned tenant pools only. The primary pool and every
    # app-owned pool are untouched: the same Rails defect affects them, but they are
    # not ours and the blast radius there is one connection of N, not a dead tenant.
    module PoolHeal
      attr_accessor :apartment_tenant, :apartment_pool_key, :apartment_taint_warned

      def checkin(conn)
        TransactionTaint.heal(conn, self)
        super
      end
    end

    class << self
      # Extend +pool+ with the heal. Called once, at tenant-pool creation.
      def install(pool, tenant:, pool_key:)
        return pool unless Apartment.config&.heal_tainted_connections

        pool.extend(PoolHeal)
        pool.apartment_tenant = tenant.to_s
        pool.apartment_pool_key = pool_key
        pool
      end

      # Best-effort. Must never raise: a raise here would abort ConnectionPool#checkin
      # and leak the connection out of the pool for good.
      def heal(conn, pool)
        return if conn.pinned
        return unless Apartment.adapter&.aborted_transaction?(conn)

        open_transactions = conn.open_transactions
        conn.reset!
        warn_once(pool)
        instrument(pool, open_transactions: open_transactions, healed: true)
      rescue StandardError => e
        warn("[Apartment::TransactionTaint] failed to heal a tainted connection for " \
             "'#{pool.apartment_pool_key}': #{e.class}: #{e.message}")
      end

      private

      def instrument(pool, open_transactions:, healed:)
        Instrumentation.instrument(
          'transaction_taint',
          tenant: pool.apartment_tenant,
          pool_key: pool.apartment_pool_key,
          open_transactions: open_transactions,
          healed: healed
        )
      end

      # Once per pool per process. The heal means each taint is a distinct incident
      # rather than a cascade, but an app that poisons on every request would
      # otherwise warn on every request — during the exact incident where the signal
      # matters. The notification fires every time; it is the countable channel.
      def warn_once(pool)
        return if pool.apartment_taint_warned

        pool.apartment_taint_warned = true
        warn(
          "[Apartment] connection for tenant '#{pool.apartment_tenant}' was checked in " \
          'while in an aborted transaction (PostgreSQL PQTRANS_INERROR) and has been ' \
          'reset. Something ran a statement that failed inside a transaction Rails did ' \
          'not unwind. Wrap the failing call in ActiveRecord::Base.transaction(requires_new: true) ' \
          'to contain it. Subscribe to transaction_taint.apartment to find the call site. ' \
          'See docs/testing.md.'
        )
      end
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/unit/transaction_taint_spec.rb`
Expected: PASS (13 examples: 5 from Task 1, 8 here).

- [ ] **Step 5: RuboCop and commit**

```bash
bundle exec rubocop lib/apartment/transaction_taint.rb spec/unit/transaction_taint_spec.rb
git add lib/apartment/transaction_taint.rb spec/unit/transaction_taint_spec.rb
git commit -m "Feat(v4): heal PQTRANS_INERROR tenant connections at pool checkin"
```

---

### Task 4: Wire the healer into tenant-pool creation

**Files:**
- Modify: `lib/apartment/patches/connection_handling.rb` (inside the `fetch_or_create` block, after `establish_connection` returns the pool — currently ~line 76-98)
- Test: `spec/unit/patches/connection_handling_spec.rb`

**Interfaces:**
- Consumes: `Apartment::TransactionTaint.install(pool, tenant:, pool_key:)` (Task 3).

**Placement matters.** Install *after* the post-establish checks and their `deregister_shard` rescue, so a pool that fails `check_pending_migrations?` is never extended (it is about to be thrown away). Install *before* returning the pool, so the very first checkin is covered.

- [ ] **Step 1: Write the failing test**

Append to `spec/unit/patches/connection_handling_spec.rb` (inside the existing top-level describe, matching its established setup for a configured adapter and pool manager):

```ruby
  describe 'transaction-taint healing' do
    it 'extends a newly created tenant pool with the checkin heal' do
      pool = ActiveRecord::Base.connection_pool
      expect(pool).to be_a(Apartment::TransactionTaint::PoolHeal)
    end

    it 'stamps the pool with the tenant and pool key for the event payload' do
      pool = ActiveRecord::Base.connection_pool
      expect([pool.apartment_tenant, pool.apartment_pool_key])
        .to eq(['acme', 'acme:writing'])
    end
  end
```

> **Note for the implementer:** this spec file already builds a tenant context. Wrap the two examples in whatever `Apartment::Tenant.switch('acme') { ... }` / `Current.tenant = 'acme'` setup the surrounding examples use — read the file and follow its pattern rather than inventing a new one. The assertions above are what must hold.

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/unit/patches/connection_handling_spec.rb -e 'transaction-taint healing'`
Expected: FAIL — the pool is a plain `ConnectionPool`, not a `PoolHeal`.

- [ ] **Step 3: Install the healer at pool creation**

In `lib/apartment/patches/connection_handling.rb`, replace the tail of the `fetch_or_create` block. It currently ends:

```ruby
          begin
            raise(Apartment::PendingMigrationError, tenant) if check_pending_migrations?(pool)

            load_tenant_schema_cache(tenant, pool) if cfg.schema_cache_per_tenant
          rescue StandardError
            Apartment.deregister_shard(pool_key)
            raise
          end

          pool
        end
```

Change it to:

```ruby
          begin
            raise(Apartment::PendingMigrationError, tenant) if check_pending_migrations?(pool)

            load_tenant_schema_cache(tenant, pool) if cfg.schema_cache_per_tenant
          rescue StandardError
            Apartment.deregister_shard(pool_key)
            raise
          end

          # After the post-establish checks (a pool that fails them is discarded and
          # must not be extended), before the pool is handed out (so the very first
          # checkin is covered). See docs/designs/transaction-taint-detection.md.
          Apartment::TransactionTaint.install(pool, tenant: tenant, pool_key: pool_key)

          pool
        end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/unit/patches/connection_handling_spec.rb`
Expected: PASS.

Then: `bundle exec rspec spec/unit/`
Expected: PASS.

- [ ] **Step 5: RuboCop and commit**

```bash
bundle exec rubocop lib/apartment/patches/connection_handling.rb spec/unit/patches/connection_handling_spec.rb
git add lib/apartment/patches/connection_handling.rb spec/unit/patches/connection_handling_spec.rb
git commit -m "Feat(v4): install the taint healer on tenant pools at creation"
```

---

### Task 5: Integration spec — reproduce the taint and prove the heal

The unit tests use doubles. This proves it against a real PostgreSQL connection and the real Rails fixture lifecycle. **Do not mock `transaction_status` here** — the whole point is that the previous design was wrong about behavior no double would have caught.

**Files:**
- Create: `spec/integration/v4/transaction_taint_spec.rb`

**Interfaces:**
- Consumes: everything from Tasks 1–4.

**The five properties, and why each is here** (all five were verified during design; this spec is the regression lock):
- **A** — a raw failing statement under an open transaction taints the connection, and AR does not roll it back.
- **B** — `transaction(requires_new: true)` heals it. This is the containment recipe we document, so it must be true.
- **C** — the heal fires at checkin and the next lease is clean (the production failure).
- **D** — the tenant's `search_path` survives `reset!`'s `DISCARD ALL`. **If this ever regresses, healing silently repoints a tenant connection at the `public` schema — a cross-tenant leak, strictly worse than the bug being fixed.**
- **E** — a fixture-pinned connection is NOT healed and its fixture transaction survives.

- [ ] **Step 1: Write the spec**

Create `spec/integration/v4/transaction_taint_spec.rb`:

```ruby
# frozen_string_literal: true

require 'spec_helper'
require_relative 'support'
require 'apartment/test_fixtures'

# Integration coverage for failure-class member 7 (W1).
# Design: docs/designs/transaction-taint-detection.md
#
# PostgreSQL only: MySQL fails the statement, not the transaction, and its raw
# connection has no transaction_status at all (Evidence E in the design doc).
RSpec.describe('v4 transaction taint heal', :integration, # rubocop:disable RSpec/MultipleMemoizedHelpers
               skip: (V4_INTEGRATION_AVAILABLE && V4IntegrationHelper.postgresql? ? false : 'requires PostgreSQL')) do
  include V4IntegrationHelper

  if V4_INTEGRATION_AVAILABLE
    # Drives the real Rails transactional-fixture lifecycle, exactly as
    # rspec-rails does around every example.
    class TaintFixtureHost
      include ActiveRecord::TestFixtures
      prepend Apartment::TestFixtures

      def initialize = @saved_pool_configs = Hash.new { |hash, key| hash[key] = {} }
      def self.uses_transaction?(_name) = false
      def name = 'taint_fixture_host'

      def run_example
        setup_fixtures
        yield
      ensure
        teardown_fixtures
      end
    end
  end

  let(:tmp_dir)     { Dir.mktmpdir('apartment_taint') }
  let(:rand_suffix) { SecureRandom.hex(4) }
  let(:tenant)      { "acme_#{rand_suffix}" }
  let(:tenants)     { [tenant] }
  let(:table_name)  { "widgets_#{rand_suffix}" }

  before do
    V4IntegrationHelper.ensure_test_database!
    config = V4IntegrationHelper.establish_default_connection!(tmp_dir: tmp_dir)

    Apartment.configure do |c|
      c.tenant_strategy   = :schema
      c.tenants_provider  = -> { tenants }
      c.default_tenant    = 'public'
      c.check_pending_migrations = false
    end
    Apartment.adapter = V4IntegrationHelper.build_adapter(config)
    Apartment.activate!

    Apartment.adapter.create(tenant)
    Apartment::Tenant.switch(tenant) { V4IntegrationHelper.create_test_table!(table_name) }
    Apartment.reset_tenant_pools!
  end

  after do
    V4IntegrationHelper.cleanup_tenants!(tenants, Apartment.adapter)
    Apartment.clear_config
    Apartment::Current.reset
  end

  def aborted?(conn) = conn.raw_connection.transaction_status == PG::PQTRANS_INERROR

  # Leaves the connection in PQTRANS_INERROR: a transaction Rails will not unwind,
  # plus a statement Rails did not wrap.
  def poison!(conn)
    conn.begin_transaction
    begin
      conn.execute('SELECT * FROM table_that_does_not_exist')
    rescue ActiveRecord::StatementInvalid
      nil # the app swallows it and carries on
    end
  end

  describe 'the taint itself' do
    it 'A. survives a failing statement that ActiveRecord did not wrap' do
      Apartment::Tenant.switch(tenant) do
        conn = ActiveRecord::Base.connection
        poison!(conn)

        expect(aborted?(conn)).to be(true)
        expect(conn.open_transactions).to eq(1) # AR did NOT roll back
        expect { conn.execute('SELECT 1') }.to raise_error(ActiveRecord::StatementInvalid)
      end
    end

    it 'B. is contained by transaction(requires_new: true) — the recipe we document' do
      Apartment::Tenant.switch(tenant) do
        conn = ActiveRecord::Base.connection
        conn.begin_transaction

        begin
          conn.transaction(requires_new: true) do
            conn.execute('SELECT * FROM table_that_does_not_exist')
          end
        rescue ActiveRecord::StatementInvalid
          nil
        end

        expect(aborted?(conn)).to be(false)
        expect(conn.select_value('SELECT 1')).to eq(1)
      end
    end
  end

  describe 'the heal at checkin' do
    it 'C. resets a poisoned connection so the next lease is clean' do
      Apartment::Tenant.switch(tenant) do
        poison!(ActiveRecord::Base.connection)
        expect(aborted?(ActiveRecord::Base.connection)).to be(true)
      end

      # End of request: Rails returns connections to their pools.
      ActiveRecord::Base.connection_handler.clear_active_connections!(:all)

      Apartment::Tenant.switch(tenant) do
        conn = ActiveRecord::Base.connection
        expect(aborted?(conn)).to be(false)
        expect(conn.select_value("SELECT count(*) FROM #{table_name}")).to eq(0)
      end
    end

    it 'D. preserves the tenant search_path through reset!s DISCARD ALL' do
      # If this ever fails, the heal is silently repointing a tenant connection at
      # the public schema -- a CROSS-TENANT LEAK, worse than the bug it fixes.
      Apartment::Tenant.switch(tenant) do
        poison!(ActiveRecord::Base.connection)
      end

      ActiveRecord::Base.connection_handler.clear_active_connections!(:all)

      Apartment::Tenant.switch(tenant) do
        conn = ActiveRecord::Base.connection
        expect(conn.select_value('SELECT current_schema()')).to eq(tenant)
      end
    end

    it 'emits transaction_taint.apartment naming the tenant' do
      events = []
      subscriber = ->(*, payload) { events << payload }

      ActiveSupport::Notifications.subscribed(subscriber, 'transaction_taint.apartment') do
        Apartment::Tenant.switch(tenant) { poison!(ActiveRecord::Base.connection) }
        ActiveRecord::Base.connection_handler.clear_active_connections!(:all)
      end

      expect(events.first).to include(tenant: tenant, healed: true)
      expect(events.first[:pool_key]).to eq("#{tenant}:writing")
    end
  end

  describe 'fixture-pinned connections' do
    it 'E. are NOT healed, and their fixture transaction survives' do
      TaintFixtureHost.new.run_example do
        Apartment::Tenant.switch(tenant) do
          conn = ActiveRecord::Base.connection
          expect(conn.pinned).to be(true)

          begin
            conn.execute('SELECT * FROM table_that_does_not_exist')
          rescue ActiveRecord::StatementInvalid
            nil
          end
          expect(aborted?(conn)).to be(true)
        end

        # A checkin here must NOT reset the pinned connection: teardown_fixtures
        # owns that transaction's rollback.
        ActiveRecord::Base.connection_handler.clear_active_connections!(:all)

        Apartment.pool_manager.each_pair do |_key, pool|
          pool.connections.each do |conn|
            next unless conn.raw_connection

            expect(conn.open_transactions).to eq(1) # fixture tx intact
          end
        end
      end
      # teardown_fixtures completed without raising -- the assertion is that
      # run_example's ensure did not blow up.
    end
  end
end
```

- [ ] **Step 2: Run it on PostgreSQL**

Run:
```bash
DATABASE_ENGINE=postgresql bundle exec appraisal rails-8.1-postgresql \
  rspec spec/integration/v4/transaction_taint_spec.rb
```
Expected: PASS (6 examples, 0 failures).

- [ ] **Step 3: Run it across the Rails matrix**

These are ActiveRecord internals (`pinned`, `reset!`, `checkin`), so all three versions must be green.

```bash
for v in rails-7.2-postgresql rails-8.0-postgresql rails-8.1-postgresql; do
  echo "== $v"
  DATABASE_ENGINE=postgresql bundle exec appraisal $v \
    rspec spec/integration/v4/transaction_taint_spec.rb
done
```
Expected: PASS on all three.

- [ ] **Step 4: Confirm the spec correctly skips on MySQL and SQLite**

```bash
DATABASE_ENGINE=mysql bundle exec appraisal rails-8.1-mysql2 rspec spec/integration/v4/transaction_taint_spec.rb
bundle exec appraisal rails-8.1-sqlite3 rspec spec/integration/v4/transaction_taint_spec.rb
```
Expected: all examples reported as *pending/skipped* ("requires PostgreSQL"), zero failures.

- [ ] **Step 5: Run the full PG integration suite for regressions**

```bash
DATABASE_ENGINE=postgresql bundle exec appraisal rails-8.1-postgresql rspec spec/integration/v4/
```
Expected: PASS. Pay particular attention to `fixture_pool_lifecycle_spec.rb` — if the heal is reaching pinned connections, it fails there first.

- [ ] **Step 6: RuboCop and commit**

```bash
bundle exec rubocop spec/integration/v4/transaction_taint_spec.rb
git add spec/integration/v4/transaction_taint_spec.rb
git commit -m "Test(v4): integration coverage for the transaction-taint heal (PG)"
```

---

### Task 6: Regression test — `switch`'s ensure issues no SQL

The v4 dividend. v3 mutated `search_path` on switch and restored it in an `ensure`; against a tainted connection that restore silently fails, leaving the tenant context *wrong*. v4's `switch` executes no SQL, so the failure mode is gone by construction. Nothing currently asserts that, and it is now load-bearing.

**Files:**
- Modify: `spec/unit/tenant_spec.rb`

- [ ] **Step 1: Write the test**

Append to `spec/unit/tenant_spec.rb`:

```ruby
  describe 'switch executes no SQL (the v4 dividend)' do
    # v3 restored search_path in switch's ensure. Against a connection in an aborted
    # transaction that restore silently fails, leaving the tenant context WRONG
    # rather than merely broken -- exactly the bug chronomodel documents and works
    # around. v4's switch is a pure CurrentAttributes swap. Lock it: any SQL added
    # to switch reintroduces the failure mode.
    # See docs/designs/transaction-taint-detection.md ("The v4 dividend").
    it 'runs no queries entering or leaving a tenant' do
      Apartment.configure { |c| c.default_tenant = 'public' }

      queries = []
      subscriber = lambda do |*, payload|
        queries << payload[:sql] unless payload[:name] == 'SCHEMA'
      end

      ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') do
        Apartment::Tenant.switch('acme') { nil }
      end

      expect(queries).to be_empty
    end
  end
```

- [ ] **Step 2: Run it**

Run: `bundle exec rspec spec/unit/tenant_spec.rb -e 'v4 dividend'`
Expected: PASS immediately — this is a characterization test locking existing behavior, not a red-green cycle.

- [ ] **Step 3: Verify it actually bites**

Temporarily add `ActiveRecord::Base.connection.execute('SELECT 1')` to `switch`'s ensure in `lib/apartment/tenant.rb`, re-run the test, confirm it FAILS, then revert. A regression test that cannot fail is decoration.

- [ ] **Step 4: RuboCop and commit**

```bash
bundle exec rubocop spec/unit/tenant_spec.rb
git add spec/unit/tenant_spec.rb
git commit -m "Test(v4): lock the SQL-free switch ensure (v3's tainted-restore bug)"
```

---

### Task 7: Observability — the event catalog

**Files:**
- Modify: `docs/observability.md` (event catalog table, ~line 20-27)

- [ ] **Step 1: Add the event row**

In the event catalog table, after the `reaper_stopped.apartment` row:

```markdown
| `transaction_taint.apartment` | When a tenant connection is checked in while in an aborted transaction (PostgreSQL `PQTRANS_INERROR`) and reset | `tenant:`, `pool_key:`, `open_transactions:`, `healed:` |
```

- [ ] **Step 2: Add the operational note**

Immediately below the table:

```markdown
### `transaction_taint.apartment` — what to do when it fires

**This event means the gem repaired something your application broke.** A statement
failed inside a transaction that ActiveRecord did not unwind, leaving the connection in
PostgreSQL's aborted-transaction state. Apartment reset the connection at checkin, so the
tenant keeps working — but the event tells you the code that caused it is still there.

**Find the call site and contain it** with `ActiveRecord::Base.transaction(requires_new: true)`,
which bounds the failure to a savepoint. The usual causes are a statement issued outside any
transaction block while one is open (raw `execute`, DDL), an error rescued *inside* a
transaction block and swallowed, or a thread killed mid-rollback.

**Alert on a rising count, not on presence.** A steady trickle is an app bug worth fixing; a
spike means a code path is poisoning connections on every request. `healed: false` never
occurs today — the field exists so a future detect-only mode does not need a new event.

**Never respond by issuing a raw `ROLLBACK` yourself.** It destroys the *enclosing*
transaction while ActiveRecord still believes its stack is intact, raises nothing, and lets
subsequent writes autocommit. See `docs/testing.md`.
```

- [ ] **Step 3: Commit**

```bash
git add docs/observability.md
git commit -m "Docs(v4): catalog transaction_taint.apartment"
```

---

### Task 8: Consumer docs — the recipe and the hazard

The highest-value documentation in this workstream. Best-effort `ROLLBACK` loops exist in the wild, and they are *actively harmful*: they silently destroy the enclosing fixture transaction and leak writes across examples. Someone must find this before they write that loop.

**Files:**
- Modify: `docs/testing.md`

- [ ] **Step 1: Add the section**

Append a new top-level section to `docs/testing.md`:

```markdown
## Aborted transactions (PostgreSQL `PQTRANS_INERROR`)

**A statement that fails inside a PostgreSQL transaction poisons the connection.** Every
subsequent statement raises `PG::InFailedSqlTransaction` until the transaction ends.
ActiveRecord heals this automatically whenever the failing statement is inside a
`transaction` block, because it unwinds with `ROLLBACK` or `ROLLBACK TO SAVEPOINT`. The
taint survives only when a statement Rails did not wrap fails while a transaction Rails
will not unwind stays open — most commonly under transactional fixtures, where the fixture
transaction is open for the whole example.

**Apartment heals this at pool checkin**, so a poisoned connection is never served to the
next caller (see [observability](observability.md) for the `transaction_taint.apartment`
event, and `heal_tainted_connections` to disable it). Fixture-pinned connections are
deliberately left alone: their transaction belongs to `teardown_fixtures`.

### Containing it at the source

**Wrap the risky call in a savepoint.** This is Rails' expression of psql's
`ON_ERROR_ROLLBACK`, and it is the supported fix:

```ruby
ActiveRecord::Base.transaction(requires_new: true) do
  ActiveRecord::Base.connection.execute(sql_that_might_fail)
end
# the connection is usable again; only the savepoint rolled back
```

### Never write a `ROLLBACK` loop

**Do not do this**, in a test hook or anywhere else:

```ruby
# WRONG. This is actively harmful.
after do
  ActiveRecord::Base.connection_pool.connections.each do |conn|
    raw = conn.raw_connection
    raw.query('ROLLBACK') if raw.transaction_status == PG::PQTRANS_INERROR
  end
end
```

A raw `ROLLBACK` **destroys the enclosing transaction**, not just the failed statement.
Measured behaviour with an ActiveRecord savepoint stack open:

```
open_transactions inside savepoint  => 2
status after raw ROLLBACK           => IDLE     <- the whole transaction is gone
AR still believes open_transactions => 2        <- bookkeeping desynced
survived savepoint block exit       => yes      <- NO exception raised
WARNING:  there is no transaction in progress   <- the outer COMMIT hit nothing
```

**Nothing raises.** Under transactional fixtures this means the example's fixture
transaction is gone, and every subsequent write **autocommits and leaks permanently into
the database** — producing exactly the order-dependent flakes the loop was written to
prevent. If you have one of these loops, delete it; Apartment's checkin heal replaces it,
and `requires_new` fixes the call site that made you write it.
```

- [ ] **Step 2: Commit**

```bash
git add docs/testing.md
git commit -m "Docs(v4): the requires_new containment recipe and the raw-ROLLBACK hazard"
```

---

### Task 9: Draft the upstream Rails issue

**Do not file it.** Write the text; the maintainer files it. It is not Apartment's bug and our heal covers only our own pools, so the upstream fix still matters.

**Files:**
- Create: `docs/rails-upstream-active-verify-gap.md`

- [ ] **Step 1: Write the draft**

Create `docs/rails-upstream-active-verify-gap.md`:

```markdown
# Draft: upstream Rails issue — `active?` does not detect an aborted transaction

Not yet filed. Ours to report, not ours to fix: our checkin heal covers only Apartment's
tenant pools (`docs/designs/transaction-taint-detection.md`, Never #4), so the primary pool
in every Rails app remains exposed.

---

**Title:** PostgreSQL: a connection in an aborted transaction passes `active?` and is
served to the next caller

**Body:**

A PostgreSQL connection left in `PQTRANS_INERROR` is returned to the pool and handed out
again, because ActiveRecord's health check cannot see the state.

`PostgreSQLAdapter#active?` probes with `@raw_connection.query(";")`. An **empty query does
not error in an aborted transaction** — PostgreSQL returns `PGRES_EMPTY_QUERY` — so
`active?` returns `true`, `verify!` pronounces the connection healthy, and
`ConnectionPool#checkin` does not reset it. The next caller gets a connection on which
every statement raises `PG::InFailedSqlTransaction`, indefinitely, until the process
restarts.

Reproduction (Rails 7.2, 8.0 and 8.1; PostgreSQL 18):

```ruby
conn = ActiveRecord::Base.connection
conn.begin_transaction
begin
  conn.execute('SELECT * FROM missing_table')
rescue ActiveRecord::StatementInvalid
  nil # swallowed by app code
end

conn.raw_connection.transaction_status  # => PG::PQTRANS_INERROR
conn.active?                            # => true   <-- the bug
ActiveRecord::Base.connection_handler.clear_active_connections!(:all)

# next checkout, same pooled connection:
ActiveRecord::Base.connection.execute('SELECT 1')
# => ActiveRecord::StatementInvalid: PG::InFailedSqlTransaction
```

This is the same class of defect as #12330 (a failed `DEALLOCATE` inside an aborted
transaction leaving a permanently broken prepared-statement cache — "all old app servers
are now permanently broken without a restart"), which was fixed in Rails.

Suggested fix: have `active?` treat `PQTRANS_INERROR` as not-active, so the existing
`verify!` → `reconnect!` path reclaims the connection; or reset on checkin when the raw
connection reports an aborted transaction.
```

- [ ] **Step 2: Commit**

```bash
git add docs/rails-upstream-active-verify-gap.md
git commit -m "Docs: draft the upstream Rails issue for the active?/aborted-transaction gap"
```

---

### Task 10: Reconcile the superseded docs (the #471 fix)

**#471 is open and would land a claim this work refutes.** Its diff asserts the failure is
*"test-only — no production path wraps `Tenant.switch`/`switch!` with it"* and scopes the fix
as *"a recovery path in `Apartment::Tenant.switch`'s ensure block."* The first is a true
statement about the adopter's *workaround* that the doc leans on to frame the *failure class*
as test-only; Evidence C shows the failure is not. The second is the wrong seam.

**Keep the dispositions, correct the conclusions.** The 2026-07-12 adopter findings are a
faithful snapshot and stay. Doing this here rather than on #471's branch keeps one reviewable
artifact instead of two touching the same files. **Tell the maintainer to close #471 in favour
of this PR, or to merge #471 first and rebase** — do not leave both open with conflicting text.

**Files:**
- Modify: `docs/designs/fixture-pool-lifecycle.md` (member 7 row in the table; the Wishlist bullet)
- Modify: `docs/designs/v4-beta-readiness.md` (the W1 bullet in Track A; the "Member 7 (W1)" row in Resolved decisions; the Progress bullets)

- [ ] **Step 1: Correct `fixture-pool-lifecycle.md`**

Member 7's row in the failure-class table becomes:

```markdown
| 7 | `PQTRANS_INERROR` taint | **Closed** — checkin heal shipped | A statement Rails did not wrap fails while a transaction Rails will not unwind stays open. Reachable in **production**, not only under fixtures: AR's `active?` does not detect the state, so the poisoned connection is checked back in and served to the next caller — and under pool-per-tenant that is the tenant's *only* connection. Healed at pool checkin via `conn.reset!`; fixture-pinned connections are skipped. Design: [`transaction-taint-detection.md`](transaction-taint-detection.md). |
```

Replace the Wishlist bullet for member 7 with a pointer, and correct its "test-only" framing:

```markdown
- **`PQTRANS_INERROR` taint** (failure-class member 7) — ✅ **SHIPPED. Design:
  [`transaction-taint-detection.md`](transaction-taint-detection.md).** An earlier note here
  recorded the failure as *test-only*, reasoning from the fact that the adopter's `ROLLBACK`
  loop appears only in their test cleanup. That inference was wrong: their **workaround** is
  test-only, but the **failure** is not. A poisoned connection passes ActiveRecord's health
  check and is served to the next caller, so under pool-per-tenant a tenant can be dead on a
  worker until the process restarts. Shipped as a heal at pool checkin, not as a recovery path
  in `switch`'s ensure — and emphatically not as the `ROLLBACK` loop, which silently destroys
  the enclosing transaction and leaks writes across examples.
```

- [ ] **Step 2: Correct `v4-beta-readiness.md`**

The Track A W1 bullet:

```markdown
- **W1 — Member 7, `PQTRANS_INERROR` taint** ✅ **shipped.** Not the scope this doc originally
  named. Reproduction refuted both halves of the sketch: the taint is **not test-only** (a
  poisoned connection passes AR's `active?`, returns to the pool, and bricks that tenant on
  that worker until restart), and `switch`'s ensure is the **wrong seam** (it cannot observe
  that failure, and it would couple a SQL-free context swap to pool internals). Shipped as a
  detect-and-heal at **pool checkin** on Apartment-owned tenant pools, PostgreSQL-only, with
  fixture-pinned connections skipped. The raw-`ROLLBACK` recovery is documented as a hazard,
  not a fix. Design: [`transaction-taint-detection.md`](transaction-taint-detection.md).
```

The "Member 7 (W1)" row in Resolved decisions:

```markdown
| Member 7 (W1) | ✅ **Shipped — checkin heal, not a `switch` recovery path** | Taint is reachable in production, not just tests; AR's `active?` cannot see it. Healed at pool checkin. The adopter's `ROLLBACK` loop is a hazard to delete, not a pattern to adopt. |
```

Update the Progress and "Remaining beta-blocking" bullets so W1 no longer appears as
outstanding internal code work; W3 (member 9) and W6 (adopter rollout) remain.

- [ ] **Step 3: Verify no stale references remain**

```bash
grep -rn "recovery path in\|switch's ensure block\|test-only" docs/designs/ docs/*.md
```
Expected: no hit that still frames member 7 as test-only or scopes it to `switch`'s ensure.
Hits inside `transaction-taint-detection.md` that *describe and reject* those framings are
correct and should stay.

- [ ] **Step 4: Commit**

```bash
git add docs/designs/fixture-pool-lifecycle.md docs/designs/v4-beta-readiness.md
git commit -m "Docs(v4): reconcile member 7 / W1 with the shipped checkin heal"
```

---

### Task 11: Full verification before the PR

- [ ] **Step 1: Unit suite, all Rails versions**

```bash
bundle exec appraisal rspec spec/unit/
```
Expected: PASS on every appraisal.

- [ ] **Step 2: Integration, all three engines**

```bash
DATABASE_ENGINE=postgresql bundle exec appraisal rails-8.1-postgresql rspec spec/integration/v4/
DATABASE_ENGINE=mysql      bundle exec appraisal rails-8.1-mysql2     rspec spec/integration/v4/
                           bundle exec appraisal rails-8.1-sqlite3    rspec spec/integration/v4/
```
Expected: PASS. MySQL and SQLite must show the taint spec *skipped*, not failed.

- [ ] **Step 3: Integration across the PG matrix**

```bash
for v in rails-7.2-postgresql rails-8.0-postgresql; do
  DATABASE_ENGINE=postgresql bundle exec appraisal $v rspec spec/integration/v4/
done
```
Expected: PASS.

- [ ] **Step 4: RuboCop on everything changed**

```bash
bundle exec rubocop $(git diff --name-only main...HEAD | grep -E '\.rb$')
```
Expected: no offenses.

- [ ] **Step 5: Open the PR**

Body must state: the seam (checkin, not `switch`), that the taint is production-reachable and
why (`active?` cannot see it), that fixture-pinned connections are skipped by construction,
that `reset!` preserves the tenant `search_path` (and that the alternative would be a
cross-tenant leak), that it is PostgreSQL-only per Evidence E, and that the raw-`ROLLBACK`
recovery is rejected with its reproduction. Link the design doc. **Say what to do about #471**
(Task 10).

Do not self-approve; branch protection forbids it. Request review.

---

## Self-Review

**Spec coverage.** Every section of `transaction-taint-detection.md` maps to a task: What we ship items 1–2 → Tasks 1, 3, 4; item 3 (instrumentation) → Tasks 3, 7; item 4 (rate-limited warning) → Task 3 (`warn_once`); item 5 (integration spec) → Task 5; item 6 (v4 dividend regression) → Task 6; item 7 (docs) → Task 8; item 8 (upstream issue) → Task 9. The Open decision is implemented as default-on in Task 2 with the one-line flip called out. Evidence E (PG-only) is enforced by Task 1's adapter seam and Task 5 step 4's skip check. Never #1 (no raw `ROLLBACK`) is enforced by Task 3's implementation and documented in Task 8. Never #5 (not at the switch boundary) is enforced by Task 6, which locks `switch` as SQL-free.

**Placeholders.** None. Every code step carries real code; every command carries expected output. Task 4 step 1 asks the implementer to match the surrounding spec file's existing tenant-context setup rather than inventing one — the assertions are fully specified, only the fixture scaffolding is deferred to the file's own convention, which is a deliberate instruction, not a gap.

**Type consistency.** `aborted_transaction?(conn)` is defined in Task 1 and consumed in Task 3 with the same arity. `TransactionTaint.install(pool, tenant:, pool_key:)` is defined in Task 3 and called in Task 4 with exactly those keywords. `PoolHeal`'s accessors (`apartment_tenant`, `apartment_pool_key`, `apartment_taint_warned`) are defined in Task 3 and asserted in Task 4. The event name `transaction_taint` (rendered `transaction_taint.apartment` by `Instrumentation.instrument`) and its four payload keys are identical across Tasks 3, 5, and 7.

**One risk the plan cannot design away.** Task 3 relies on `conn.pinned` being a public reader on `ActiveRecord::ConnectionAdapters::AbstractAdapter`. It is, and it was verified against 7.2/8.0/8.1 during design — but it is not part of Rails' documented public API, so it is exactly the kind of thing that could be renamed in 8.2. Task 5's example E is the canary: if `pinned` disappears, that spec fails loudly rather than the heal silently eating a fixture transaction. That is the correct failure direction, and it is why example E must never be weakened into a mock.
