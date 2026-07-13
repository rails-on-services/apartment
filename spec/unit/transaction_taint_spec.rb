# frozen_string_literal: true

require 'spec_helper'

# The taint is a PostgreSQL-only state (Evidence E in the design doc), so the
# PostgresqlTransactionState examples need the pg gem to name PQTRANS_* constants.
# The default (driverless) unit bundle has no pg, so they skip there and run under
# the PostgreSQL appraisals. PG_UNIT_REQUIRED=1 turns the skip into a hard failure
# in the job that IS supposed to load pg — otherwise a bundle that quietly lost pg
# would keep reporting green while covering nothing. See spec/CLAUDE.md.
begin
  require('pg')
rescue LoadError => e
  raise if ENV['PG_UNIT_REQUIRED']

  warn "[spec] pg not loadable; skipping PostgresqlTransactionState unit examples: #{e.message}"
end

# Failure-class member 7 (W1). Design: docs/designs/transaction-taint-detection.md
RSpec.describe('transaction taint') do
  describe 'Apartment::Adapters::AbstractAdapter#aborted_transaction?' do
    let(:adapter) { Apartment::Adapters::AbstractAdapter.new({}) }
    let(:conn)    { instance_double(ActiveRecord::ConnectionAdapters::AbstractAdapter) }

    it 'is false by default — only PostgreSQL has a sticky aborted-transaction state' do
      expect(adapter.aborted_transaction?(conn)).to(be(false))
    end
  end

  describe(Apartment::Adapters::PostgresqlTransactionState,
           skip: (defined?(PG) ? false : 'requires the pg gem')) do
    let(:adapter) do
      Class.new(Apartment::Adapters::AbstractAdapter) do
        include Apartment::Adapters::PostgresqlTransactionState
      end.new({})
    end

    def conn_with(status)
      raw = instance_double(PG::Connection, transaction_status: status)
      instance_double(ActiveRecord::ConnectionAdapters::AbstractAdapter, raw_connection: raw)
    end

    it 'is true when the raw connection reports PQTRANS_INERROR' do
      expect(adapter.aborted_transaction?(conn_with(PG::PQTRANS_INERROR))).to(be(true))
    end

    it 'is false for a healthy in-transaction connection' do
      expect(adapter.aborted_transaction?(conn_with(PG::PQTRANS_INTRANS))).to(be(false))
    end

    it 'is false for an idle connection' do
      expect(adapter.aborted_transaction?(conn_with(PG::PQTRANS_IDLE))).to(be(false))
    end

    it 'is false when the connection has no raw connection yet' do
      conn = instance_double(ActiveRecord::ConnectionAdapters::AbstractAdapter, raw_connection: nil)
      expect(adapter.aborted_transaction?(conn)).to(be(false))
    end

    it 'is false — never raises — when the raw connection cannot answer' do
      conn = instance_double(ActiveRecord::ConnectionAdapters::AbstractAdapter,
                             raw_connection: Object.new)
      expect(adapter.aborted_transaction?(conn)).to(be(false))
    end
  end
end
