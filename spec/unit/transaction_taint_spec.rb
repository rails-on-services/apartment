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

    # Deliberately NOT an instance_double stubbing `raw_connection`. That double is
    # what hid the original bug: it made AR's `raw_connection` — a method that
    # materializes transactions and OPENS an unconnected connection — look like a
    # pure reader. This fake mirrors AR's real shape instead: a `connected?`
    # predicate over an @raw_connection ivar. It also FAILS LOUDLY if the detector
    # ever reaches for `raw_connection` again.
    let(:fake_conn) do
      Class.new do
        def initialize(raw) = @raw_connection = raw
        def connected? = !@raw_connection.nil?

        def raw_connection
          raise('detector must not call raw_connection — it has side effects')
        end
      end
    end

    def conn_with(status)
      fake_conn.new(instance_double(PG::Connection, transaction_status: status))
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

    it 'is false — and does NOT connect — when the connection is not yet connected' do
      expect(adapter.aborted_transaction?(fake_conn.new(nil))).to(be(false))
    end

    it 'is false — never raises — when the raw connection cannot answer' do
      expect(adapter.aborted_transaction?(fake_conn.new(Object.new))).to(be(false))
    end
  end
end

RSpec.describe(Apartment::TransactionTaint) do
  # Stands in for ActiveRecord's ConnectionPool. `checkin` only records the call,
  # so `super` running (or not) is observable.
  let(:pool_class) do
    Class.new do
      attr_reader :checked_in

      def initialize
        @checked_in = []
      end

      def checkin(conn)
        @checked_in << conn
      end
    end
  end

  let(:pool)    { pool_class.new }
  let(:adapter) { instance_double(Apartment::Adapters::AbstractAdapter) }

  def configure_apartment(heal: true)
    Apartment.configure do |c|
      c.tenant_strategy = :schema
      c.tenants_provider = -> { [] }
      c.default_tenant = 'public'
      c.heal_tainted_connections = heal
    end
  end

  def connection(aborted:, pinned: false, open_transactions: 1)
    conn = instance_double(ActiveRecord::ConnectionAdapters::AbstractAdapter,
                           pinned: pinned,
                           open_transactions: open_transactions)
    allow(conn).to(receive(:reset!))
    allow(conn).to(receive(:disconnect!))
    allow(adapter).to(receive(:aborted_transaction?).with(conn).and_return(aborted))
    conn
  end

  before do
    configure_apartment
    allow(Apartment).to(receive(:adapter).and_return(adapter))
    allow(described_class).to(receive(:warn)) # keep the suite output clean
    described_class.install(pool, tenant: 'acme', pool_key: 'acme:writing')
  end

  it 'resets a connection left in an aborted transaction' do
    conn = connection(aborted: true)
    pool.checkin(conn)
    expect(conn).to(have_received(:reset!))
  end

  it 'still checks the connection in after healing it' do
    conn = connection(aborted: true)
    pool.checkin(conn)
    expect(pool.checked_in).to(eq([conn]))
  end

  it 'leaves a healthy connection alone' do
    conn = connection(aborted: false)
    pool.checkin(conn)
    expect(conn).not_to(have_received(:reset!))
  end

  # The invariant that lets ONE seam serve both populations: a fixture-pinned
  # connection's transaction belongs to teardown_fixtures. Resetting it here would
  # destroy the fixture transaction and let subsequent writes autocommit.
  it 'SKIPS a fixture-pinned connection' do
    conn = connection(aborted: true, pinned: true)
    pool.checkin(conn)
    expect(conn).not_to(have_received(:reset!))
  end

  it 'still checks a pinned connection in' do
    conn = connection(aborted: true, pinned: true)
    pool.checkin(conn)
    expect(pool.checked_in).to(eq([conn]))
  end

  it 'emits transaction_taint.apartment naming the tenant' do
    conn = connection(aborted: true, open_transactions: 2)
    events = []

    ActiveSupport::Notifications.subscribed(->(*, payload) { events << payload },
                                            'transaction_taint.apartment') do
      pool.checkin(conn)
    end

    expect(events.first).to(include(tenant: 'acme', pool_key: 'acme:writing',
                                    open_transactions: 2, healed: true))
  end

  it 'warns once per pool, not once per taint' do
    allow(described_class).to(receive(:warn))
    3.times { pool.checkin(connection(aborted: true)) }
    expect(described_class).to(have_received(:warn).once)
  end

  # A raise here would abort ConnectionPool#checkin and leak the connection out of
  # the pool for good -- strictly worse than the taint.
  it 'never raises out of checkin, even when reset! blows up' do
    conn = connection(aborted: true)
    allow(conn).to(receive(:reset!).and_raise(StandardError, 'boom'))
    expect { pool.checkin(conn) }.not_to(raise_error)
  end

  it 'still checks the connection in when the heal itself failed' do
    conn = connection(aborted: true)
    allow(conn).to(receive(:reset!).and_raise(StandardError, 'boom'))
    pool.checkin(conn)
    expect(pool.checked_in).to(eq([conn]))
  end

  # Checking a STILL-POISONED connection back in would rebuild the outage this whole
  # feature exists to prevent: the next lease gets it and the tenant stays dead. Drop
  # the handle instead; Rails reconnects it, fresh, on the next checkout.
  it 'DISCARDS the connection when reset! fails, rather than re-pooling it poisoned' do
    conn = connection(aborted: true)
    allow(conn).to(receive(:reset!).and_raise(StandardError, 'boom'))
    pool.checkin(conn)
    expect(conn).to(have_received(:disconnect!))
  end

  it 'reports the failed heal as healed: false with the error class' do
    conn = connection(aborted: true)
    allow(conn).to(receive(:reset!).and_raise(StandardError, 'boom'))
    events = []

    ActiveSupport::Notifications.subscribed(->(*, payload) { events << payload },
                                            'transaction_taint.apartment') do
      pool.checkin(conn)
    end

    expect(events.first).to(include(healed: false, error: 'StandardError'))
  end

  it 'never raises even when the discard fallback ALSO fails' do
    conn = connection(aborted: true)
    allow(conn).to(receive(:reset!).and_raise(StandardError, 'boom'))
    allow(conn).to(receive(:disconnect!).and_raise(StandardError, 'boom too'))
    expect { pool.checkin(conn) }.not_to(raise_error)
  end

  it 'does not extend the pool at all when heal_tainted_connections is false' do
    configure_apartment(heal: false)
    plain = pool_class.new
    described_class.install(plain, tenant: 'acme', pool_key: 'acme:writing')
    expect(plain).not_to(be_a(described_class::PoolHeal))
  end
end
