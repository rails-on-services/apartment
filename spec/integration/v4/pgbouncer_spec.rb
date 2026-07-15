# frozen_string_literal: true

require 'spec_helper'

# Guards the pooler-safety claims in docs/connection-poolers.md.
#
# Runs only in the `pgbouncer` CI job, which stands up TWO PgBouncer instances in
# transaction mode against one PostgreSQL:
#
#   PGBOUNCER_SAFE_PORT   — track_extra_parameters = IntervalStyle,search_path
#   PGBOUNCER_UNSAFE_PORT — PgBouncer defaults (IntervalStyle only)
#
# Both run default_pool_size=1, forcing every client onto ONE backend. That is the
# whole point: without a shared backend there is nothing to cross, and a green test
# would prove nothing. Every example therefore asserts `shared_backend` first — if the
# clients never met on a backend, the isolation result is meaningless.
#
# What the expectations encode (full matrix: docs/designs/w4-pgbouncer-libpq-spike.md):
#
#   PG >= 18, safe config    -> ISOLATED, and genuinely multiplexed
#   PG >= 18, default config -> LEAKS
#   PG <= 17, either config  -> LEAKS  (the version floor: search_path is not reported
#                                       to clients before PG 18, so PgBouncer cannot
#                                       track it and the safe config is inert)
#
# We deliberately assert the LEAKING cases too. They are not decoration: if PostgreSQL
# or PgBouncer changes this underneath us — say PG 17 backports the reporting, or a new
# PgBouncer tracks search_path by default — these expectations fail, and we correct the
# docs instead of letting them rot into a lie about tenant isolation.
#
# The spec issues `SET search_path TO "<tenant>"` on a raw pg connection. That is
# byte-for-byte what Rails does when establishing a connection for an Apartment tenant
# pool: PostgresqlSchemaAdapter#resolve_connection_config puts `schema_search_path` in
# the connection config and Rails' configure_connection applies it with one SET. Staying
# at the protocol level exercises the exact mechanism without booting Apartment, and
# keeps this spec clear of the AR connection handler that the other integration specs
# swap out.
module PgBouncerSpec
  TENANT_A = 'pgb_tenant_a'
  TENANT_B = 'pgb_tenant_b'
  ROW_A = 'AAA-tenant-a'
  ROW_B = 'BBB-tenant-b'

  module_function

  def driver?
    require('pg')
    true
  rescue LoadError
    false
  end

  def ports_configured?
    [ENV.fetch('PGBOUNCER_SAFE_PORT', nil), ENV.fetch('PGBOUNCER_UNSAFE_PORT', nil)]
      .all? { |port| port.to_s.match?(/\A\d+\z/) }
  end

  # Graceful skip on a laptop; hard failure in the CI job that is supposed to provide
  # the poolers. A silently-skipped tenant-isolation test that reports green is exactly
  # the failure this spec exists to prevent (see spec/CLAUDE.md, "CI hard-fail flags").
  def skip_reason
    return false if driver? && ports_configured?

    reason = 'requires the pgbouncer CI job (PGBOUNCER_SAFE_PORT / PGBOUNCER_UNSAFE_PORT + pg driver)'
    raise("PGBOUNCER_REQUIRED is set but the spec cannot run: #{reason}") if ENV['PGBOUNCER_REQUIRED']

    reason
  end

  def base_params
    { host: ENV.fetch('PGHOST', '127.0.0.1'),
      dbname: ENV.fetch('PGDATABASE', 'apartment_v4_test'),
      user: ENV.fetch('PGUSER', 'postgres') }
  end

  def direct_connect
    PG.connect(**base_params, port: ENV.fetch('PGPORT', '5432'))
  end

  def pooled_connect(port, tenant)
    conn = PG.connect(**base_params, port: port)
    # Exactly what Rails issues for an Apartment tenant pool.
    conn.exec(%(SET search_path TO "#{tenant}"))
    conn
  end

  def server_major
    conn = direct_connect
    conn.exec('SHOW server_version_num').getvalue(0, 0).to_i / 10_000
  ensure
    conn&.close
  end

  # Two tenants, one pooler, forced onto one backend. Reports what actually happened
  # rather than asserting inline, so each example can state its own expectation.
  def observe(port)
    conn_a = pooled_connect(port, TENANT_A)
    conn_b = pooled_connect(port, TENANT_B)
    correct = []
    pids = []

    3.times do
      [[conn_a, ROW_A], [conn_b, ROW_B]].each do |conn, expected|
        result = conn.exec('SELECT owner, pg_backend_pid() FROM widgets')
        correct << (result.getvalue(0, 0) == expected)
        pids << result.getvalue(0, 1)
      rescue PG::Error
        # A wrong search_path can also surface as "relation does not exist" rather
        # than wrong rows. Either way the tenant did not get its own data.
        correct << false
      end
    end

    { isolated: correct.all?, shared_backend: pids.uniq.size == 1 }
  ensure
    [conn_a, conn_b].each { |conn| conn&.close }
  end
end

RSpec.describe('PgBouncer transaction-mode tenant isolation', :pgbouncer,
               skip: PgBouncerSpec.skip_reason) do
  before(:all) do
    # DDL goes straight to PostgreSQL, bypassing both poolers. No public.widgets is
    # created on purpose: a search_path miss must fail or read the wrong tenant, never
    # quietly resolve to a shared table.
    conn = PgBouncerSpec.direct_connect
    [[PgBouncerSpec::TENANT_A, PgBouncerSpec::ROW_A],
     [PgBouncerSpec::TENANT_B, PgBouncerSpec::ROW_B]].each do |schema, owner|
      conn.exec("DROP SCHEMA IF EXISTS #{schema} CASCADE")
      conn.exec("CREATE SCHEMA #{schema}")
      conn.exec("CREATE TABLE #{schema}.widgets (id int primary key, owner text)")
      conn.exec("INSERT INTO #{schema}.widgets VALUES (1, '#{owner}')")
    end
  ensure
    conn&.close
  end

  let(:safe_port) { ENV.fetch('PGBOUNCER_SAFE_PORT') }
  let(:unsafe_port) { ENV.fetch('PGBOUNCER_UNSAFE_PORT') }
  let(:server_major) { PgBouncerSpec.server_major }

  describe 'the mechanism PgBouncer depends on' do
    # PgBouncer can only track a parameter the server REPORTS back to the client.
    # This is the single fact that decides whether transaction mode can ever be safe.
    it 'reports search_path to clients on PG 18+, and not before' do
      conn = PG.connect(
        **PgBouncerSpec.base_params,
        port: ENV.fetch('PGPORT', '5432'),
        options: "-c search_path=#{PgBouncerSpec::TENANT_A}"
      )
      reported = conn.parameter_status('search_path')

      if server_major >= 18
        expect(reported).to(eq(PgBouncerSpec::TENANT_A))
      else
        expect(reported).to(be_nil)
      end
    ensure
      conn&.close
    end
  end

  describe 'safe config (track_extra_parameters includes search_path)' do
    it 'isolates tenants and genuinely multiplexes them onto a shared backend (PG 18+)' do
      skip('PG <= 17 — see the version-floor example below') if server_major < 18

      result = PgBouncerSpec.observe(safe_port)

      expect(result[:shared_backend]).to(be(true),
                                         'clients never shared a backend — this test proved nothing')
      expect(result[:isolated]).to(be(true))
    end

    it 'still LEAKS on PG <= 17 — the server never reports search_path, so tracking is inert' do
      skip('PG 18+ — tracking works; see the example above') if server_major >= 18

      result = PgBouncerSpec.observe(safe_port)

      expect(result[:shared_backend]).to(be(true))
      # Documents WHY docs/connection-poolers.md calls PG <= 17 unsupported: the config
      # looks correct and does nothing. If this ever passes as isolated, the floor moved
      # and the docs must change.
      expect(result[:isolated]).to(be(false))
    end
  end

  describe 'default config (PgBouncer does not track search_path)' do
    it 'LEAKS across tenants on every PostgreSQL version' do
      result = PgBouncerSpec.observe(unsafe_port)

      expect(result[:shared_backend]).to(be(true))
      expect(result[:isolated]).to(be(false))
    end
  end
end
