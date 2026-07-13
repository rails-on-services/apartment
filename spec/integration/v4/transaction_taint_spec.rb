# frozen_string_literal: true

require 'spec_helper'
require_relative 'support'
require 'apartment/test_fixtures'

# Integration coverage for failure-class member 7 (W1).
# Design: docs/designs/transaction-taint-detection.md
#
# Nothing here is mocked. The previous design of this feature was wrong about
# behaviour no double would have caught (it assumed the taint was test-only, and
# that a poisoned connection could not reach the next request), so this spec drives
# a real PostgreSQL connection and the real Rails fixture lifecycle.
#
# PostgreSQL only: MySQL fails the statement, not the transaction, and its raw
# connection has no transaction_status at all (Evidence E in the design doc).
RSpec.describe('v4 transaction taint heal', :integration,
               skip: (V4_INTEGRATION_AVAILABLE && V4IntegrationHelper.postgresql? ? false : 'requires PostgreSQL')) do
  include V4IntegrationHelper

  if V4_INTEGRATION_AVAILABLE
    # Drives the real Rails transactional-fixture lifecycle, exactly as rspec-rails
    # does around every example.
    class TaintFixtureHost
      include ActiveRecord::TestFixtures
      prepend Apartment::TestFixtures

      def initialize
        @saved_pool_configs = Hash.new { |hash, key| hash[key] = {} }
      end

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
  # plus a statement Rails did not wrap. This is the whole failure class in four
  # lines.
  def poison!(conn)
    conn.begin_transaction
    begin
      conn.execute('SELECT * FROM table_that_does_not_exist')
    rescue ActiveRecord::StatementInvalid
      nil # the app swallows it and carries on
    end
  end

  describe 'the taint itself' do
    it 'survives a failing statement that ActiveRecord did not wrap' do
      Apartment::Tenant.switch(tenant) do
        conn = ActiveRecord::Base.connection
        poison!(conn)

        expect(aborted?(conn)).to(be(true))
        expect(conn.open_transactions).to(eq(1)) # AR did NOT roll back
        expect { conn.execute('SELECT 1') }.to(raise_error(ActiveRecord::StatementInvalid))
      end
    end

    it 'is contained by transaction(requires_new: true) — the recipe we document' do
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

        expect(aborted?(conn)).to(be(false))
        expect(conn.select_value('SELECT 1')).to(eq(1))
      end
    end
  end

  describe 'the heal at checkin' do
    it 'resets a poisoned connection so the next lease is clean' do
      Apartment::Tenant.switch(tenant) do
        poison!(ActiveRecord::Base.connection)
        expect(aborted?(ActiveRecord::Base.connection)).to(be(true))
      end

      # End of request: Rails returns connections to their pools.
      ActiveRecord::Base.connection_handler.clear_active_connections!(:all)

      Apartment::Tenant.switch(tenant) do
        conn = ActiveRecord::Base.connection
        expect(aborted?(conn)).to(be(false))
        expect(conn.select_value("SELECT count(*) FROM #{table_name}")).to(eq(0))
      end
    end

    # reset! issues DISCARD ALL, which resets session state. If it dropped the
    # pool's schema_search_path, the heal would silently repoint a tenant connection
    # at the public schema -- a CROSS-TENANT LEAK, strictly worse than the bug being
    # fixed. attempt_configure_connection re-applies it. This example is the guard.
    it 'preserves the tenant search_path through reset!s DISCARD ALL' do
      Apartment::Tenant.switch(tenant) { poison!(ActiveRecord::Base.connection) }

      ActiveRecord::Base.connection_handler.clear_active_connections!(:all)

      Apartment::Tenant.switch(tenant) do
        conn = ActiveRecord::Base.connection
        expect(conn.select_value('SELECT current_schema()')).to(eq(tenant))
      end
    end

    it 'emits transaction_taint.apartment naming the tenant' do
      events = []
      subscriber = ->(*, payload) { events << payload }

      ActiveSupport::Notifications.subscribed(subscriber, 'transaction_taint.apartment') do
        Apartment::Tenant.switch(tenant) { poison!(ActiveRecord::Base.connection) }
        ActiveRecord::Base.connection_handler.clear_active_connections!(:all)
      end

      expect(events.first).to(include(tenant: tenant, pool_key: "#{tenant}:writing", healed: true))
    end

    it 'leaves a healthy connection untouched' do
      events = []
      subscriber = ->(*, payload) { events << payload }

      ActiveSupport::Notifications.subscribed(subscriber, 'transaction_taint.apartment') do
        Apartment::Tenant.switch(tenant) do
          ActiveRecord::Base.connection.select_value("SELECT count(*) FROM #{table_name}")
        end
        ActiveRecord::Base.connection_handler.clear_active_connections!(:all)
      end

      expect(events).to(be_empty)
    end
  end

  describe 'fixture-pinned connections' do
    # The invariant that lets ONE seam serve both populations. A pinned connection's
    # transaction belongs to teardown_fixtures; healing it would destroy the fixture
    # transaction and let every subsequent write autocommit and leak across examples.
    # If AR ever renames `pinned`, this is the example that fails -- loudly, and in
    # the right direction. Do not weaken it into a mock.
    it 'are NOT healed, and their fixture transaction survives' do
      TaintFixtureHost.new.run_example do
        Apartment::Tenant.switch(tenant) do
          conn = ActiveRecord::Base.connection
          expect(conn.pinned).to(be(true))

          begin
            conn.execute('SELECT * FROM table_that_does_not_exist')
          rescue ActiveRecord::StatementInvalid
            nil
          end
          expect(aborted?(conn)).to(be(true))
        end

        # A checkin here must NOT reset the pinned connection.
        ActiveRecord::Base.connection_handler.clear_active_connections!(:all)

        Apartment.pool_manager.each_pair do |_key, pool|
          pool.connections.each do |conn|
            next unless conn.raw_connection

            expect(conn.open_transactions).to(eq(1)) # fixture transaction intact
          end
        end
      end
      # The real assertion for teardown is that run_example's ensure did not raise.
    end
  end
end
