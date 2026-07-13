# frozen_string_literal: true

module Apartment
  # Heals a tenant connection left in an aborted transaction (PostgreSQL's
  # PQTRANS_INERROR) at the moment it is checked back into its pool.
  #
  # WHY CHECKIN. ActiveRecord's +active?+ probes with an empty query, which does
  # NOT error in an aborted transaction, so +verify!+ pronounces a poisoned
  # connection healthy and +checkin+ does not reset it. The pool then serves it to
  # the next caller. Under pool-per-tenant that connection is the ONLY connection
  # for its tenant, so the tenant is dead on that worker until the process
  # restarts, while every other tenant looks fine and nothing in the logs explains
  # it. That amplification is what makes this ours to fix: the defect is generic
  # Rails/PG, the consequence is specific to pool-per-tenant.
  #
  # Checkin is also the one seam that serves both populations correctly. A
  # FIXTURE-PINNED connection must KEEP its transaction (teardown_fixtures owns the
  # rollback) and never reaches ConnectionPool#checkin's body; a production
  # connection must be reset before reuse. We still test +pinned+ explicitly,
  # because this override runs BEFORE the early return in AR's own +checkin+.
  #
  # NEVER issue a raw ROLLBACK here. It destroys the ENCLOSING transaction while
  # ActiveRecord still believes its stack is intact, raises nothing, and lets
  # subsequent writes autocommit — turning a loud failure into silent, permanent
  # database pollution. +reset!+ is ActiveRecord's own primitive: it rolls back,
  # DISCARDs session state, and resets AR's transaction bookkeeping together. It
  # also re-applies the pool's schema_search_path, so a healed tenant connection
  # still points at its own schema (verified — the alternative would be a
  # cross-tenant leak, which is strictly worse than the bug being fixed).
  #
  # Design: docs/designs/transaction-taint-detection.md
  module TransactionTaint
    # Extended onto Apartment-owned tenant pools only. The primary pool and every
    # app-owned pool are left alone: the same Rails defect reaches them, but they
    # are not ours, and the blast radius there is one connection of N rather than a
    # dead tenant. That gap is reported upstream, not patched here.
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

      # Best-effort, and it must never raise: an exception here would abort
      # ConnectionPool#checkin and leak the connection out of the pool permanently,
      # which is worse than the taint we came to fix.
      def heal(conn, pool)
        return if conn.pinned
        return unless Apartment.adapter&.aborted_transaction?(conn)

        open_transactions = conn.open_transactions
        conn.reset!
        warn_once(pool)
        instrument(pool, open_transactions: open_transactions)
      rescue StandardError => e
        warn('[Apartment::TransactionTaint] failed to heal a tainted connection for ' \
             "'#{pool.apartment_pool_key}': #{e.class}: #{e.message}")
      end

      private

      def instrument(pool, open_transactions:)
        Instrumentation.instrument(
          'transaction_taint',
          tenant: pool.apartment_tenant,
          pool_key: pool.apartment_pool_key,
          open_transactions: open_transactions,
          healed: true
        )
      end

      # Once per pool per process. Healing means each taint is a distinct incident
      # rather than a cascade, but an app that poisons on every request would still
      # warn on every request — flooding the log during the exact incident where the
      # signal matters. The notification fires every time; it is the countable
      # channel, and the one to alert on.
      def warn_once(pool)
        return if pool.apartment_taint_warned

        pool.apartment_taint_warned = true
        warn(
          "[Apartment] the connection for tenant '#{pool.apartment_tenant}' was checked in " \
          'while in an aborted transaction (PostgreSQL PQTRANS_INERROR) and has been reset. ' \
          'Something ran a statement that failed inside a transaction Rails did not unwind. ' \
          'Contain it by wrapping the failing call in ' \
          'ActiveRecord::Base.transaction(requires_new: true); subscribe to ' \
          'transaction_taint.apartment to find the call site. Do NOT add a raw ROLLBACK loop — ' \
          'see docs/testing.md.'
        )
      end
    end
  end
end
