# frozen_string_literal: true

require 'spec_helper'
require_relative 'support'

# Pool-per-tenant rebuilds the PostgreSQL OID type map on every cold tenant pool:
# configure_connection ends in reload_type_map, which runs three pg_type queries,
# two of them sequential scans of a catalog that grows with every tenant schema.
# The patch shares one map per database across every adapter in the process.
# See docs/designs/postgresql-type-map-sharing.md.
RSpec.describe('v4 PostgreSQL type-map sharing', :integration,
               skip: (V4_INTEGRATION_AVAILABLE && V4IntegrationHelper.postgresql? ? false : 'requires PostgreSQL')) do
  include V4IntegrationHelper

  # The three statements initialize_type_map issues through load_types_queries
  # all join pg_range; the lazy single-OID variant get_oid_type issues does too
  # but filters on t.oid. add_pg_decoders has its own, join-less shape.
  def type_map_loads(sql) = sql.grep(/LEFT JOIN pg_range/i).grep_v(/WHERE t\.oid IN/)
  def lazy_oid_loads(sql) = sql.grep(/WHERE t\.oid IN/)
  def decoder_lookups(sql) = sql.grep(/SELECT t\.oid, t\.typname\s+FROM pg_type as t\s+WHERE t\.typname IN/)

  # Rails main (post-8.1) hard-codes the well-known OIDs (OID::WellKnown) and
  # defers the one remaining bulk pg_type scan to the first unknown OID, so a
  # connect touches pg_type zero times there and the sharing instead saves the
  # deferred scan once per process rather than once per adapter. The examples
  # that pin connect-time behavior feature-detect that, rather than a version.
  def connect_time_catalog_queries? = !defined?(ActiveRecord::ConnectionAdapters::PostgreSQL::OID::WellKnown)

  let(:tmp_dir) { Dir.mktmpdir('apartment_pg_type_map') }
  let(:created_tenants) { [] }

  before do
    V4IntegrationHelper.ensure_test_database!
    config = V4IntegrationHelper.establish_default_connection!(tmp_dir: tmp_dir)

    Apartment.configure do |c|
      c.tenant_strategy = :schema
      c.tenants_provider = -> { [] }
      c.default_tenant = 'public'
      c.check_pending_migrations = false
    end

    Apartment.adapter = V4IntegrationHelper.build_adapter(config)
    Apartment.activate!

    %w[tm_a tm_b tm_c].each do |name|
      Apartment.adapter.create(name)
      created_tenants << name
    end
  end

  after do
    V4IntegrationHelper.cleanup_tenants!(created_tenants, Apartment.adapter)
    Apartment.clear_config
    Apartment::Current.reset
  end

  def pg_type_sql_during
    seen = []
    subscription = ActiveSupport::Notifications.subscribe('sql.active_record') do |event|
      sql = event.payload[:sql]
      seen << sql if sql.include?('pg_type')
    end
    yield
    seen
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription)
  end

  def touch_every_tenant
    created_tenants.each do |tenant|
      Apartment::Tenant.switch(tenant) { ActiveRecord::Base.connection.select_value('SELECT 1') }
    end
  end

  it 'is prepended on the real adapter by the gem-load hook' do
    expect(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter.ancestors)
      .to(include(Apartment::Patches::PostgresqlTypeMap))
  end

  it 'loads the OID type map once per database across cold tenant pools' do
    # Asserts a connect-time cost that Rails main does not pay at all, so there
    # it would hold with the patch reverted. The raw-DDL example below is the
    # one that carries the sharing claim on main.
    skip('Rails main runs no connect-time catalog queries') unless connect_time_catalog_queries?

    Apartment.reset_tenant_pools!
    Apartment::Patches::PostgresqlTypeMap.reset!

    first = pg_type_sql_during do
      Apartment::Tenant.switch(created_tenants.first) { ActiveRecord::Base.connection.select_value('SELECT 1') }
    end
    rest = pg_type_sql_during do
      3.times do
        touch_every_tenant
        Apartment.reset_tenant_pools! # evict, so the next round opens three fresh connections
      end
    end

    # The first cold connection loads (three statements) and the nine after it
    # adopt. Without sharing every one of the ten would load: 30.
    expect(type_map_loads(first).size).to(eq(3))
    expect(type_map_loads(rest)).to(be_empty)
  end

  it 'still runs the per-connection decoder lookup, which this patch leaves alone' do
    skip('Rails main resolves decoder OIDs from OID::WellKnown') unless connect_time_catalog_queries?

    Apartment.reset_tenant_pools!

    sql = pg_type_sql_during { touch_every_tenant }

    expect(decoder_lookups(sql).size).to(eq(created_tenants.size))
  end

  it 'republishes after create_enum, so a fresh connection resolves the new type with no lazy load' do
    # Rails main's rebuild registers well-known types only and defers the rest, so
    # the enum is learned at first sight there; the raw-DDL example below pins that
    # the deferred load is shared.
    skip('Rails main defers the bulk load past reload_type_map') unless connect_time_catalog_queries?

    tenant = created_tenants.first
    Apartment::Tenant.switch(tenant) do
      conn = ActiveRecord::Base.connection
      conn.create_enum(:tm_mood, %w[sad ok])
      conn.create_table(:tm_moods) { |t| t.enum(:mood, enum_type: :tm_mood) }
      conn.execute("INSERT INTO tm_moods (mood) VALUES ('ok')")
    end
    Apartment.reset_tenant_pools!

    model = Class.new(ActiveRecord::Base) do
      self.table_name = 'tm_moods'
      def self.name = 'TmMood'
    end

    sql = pg_type_sql_during do
      Apartment::Tenant.switch(tenant) { expect(model.pluck(:mood)).to(eq(['ok'])) }
    end

    expect(lazy_oid_loads(sql)).to(be_empty)
    expect(type_map_loads(sql)).to(be_empty)
  end

  it 'learns a type created by raw DDL lazily once, then shares it with every later connection' do
    tenant = created_tenants.last
    Apartment::Tenant.switch(tenant) do
      conn = ActiveRecord::Base.connection
      conn.execute("CREATE TYPE tm_raw_state AS ENUM ('draft', 'live')")
      conn.execute('CREATE TABLE tm_raw_widgets (id bigserial PRIMARY KEY, state tm_raw_state)')
      conn.execute("INSERT INTO tm_raw_widgets (state) VALUES ('live')")
    end
    Apartment.reset_tenant_pools!

    # A FRESH model class per read, which is load-bearing. ActiveRecord memoizes
    # column metadata -- including the resolved type object for the enum column
    # -- on the model CLASS, and that memo outlives pool eviction. Reusing one
    # class lets the second read cast from the memo without ever asking the new
    # adapter's type map, so the example would pass with the patch reverted.
    read = lambda do |class_name|
      model = Class.new(ActiveRecord::Base) do
        self.table_name = 'tm_raw_widgets'
        define_singleton_method(:name) { class_name }
      end
      Apartment::Tenant.switch(tenant) { model.pluck(:state) }
    end

    first = pg_type_sql_during { expect(read.call('TmRawWidgetA')).to(eq(['live'])) }
    Apartment.reset_tenant_pools!
    second = pg_type_sql_during { expect(read.call('TmRawWidgetB')).to(eq(['live'])) }

    # The enum was created after the shared map was built, so the first read has
    # to learn its OID the lazy way.
    expect(lazy_oid_loads(first).size).to(eq(1))
    # Both assertions on the second read are needed, and neither alone suffices:
    # a fresh connection that rebuilt the whole map would also show zero lazy
    # loads, and one that skipped the column entirely would show zero of both.
    # Together with the fresh model above they pin the actual claim -- a cold
    # connection resolved the lazily learned OID out of the shared map, querying
    # nothing.
    expect(lazy_oid_loads(second)).to(be_empty)
    expect(type_map_loads(second)).to(be_empty)
  end
end
