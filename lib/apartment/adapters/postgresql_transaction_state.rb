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
        # A connection too broken to report its own status is not ours to classify;
        # AR's own verify!/reconnect path owns that case.
        false
      end
    end
  end
end
