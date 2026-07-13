# frozen_string_literal: true

require 'spec_helper'
require_relative 'support'

# Integration coverage for out-of-band tenant DDL (W3 / failure-class member 9).
# Design: docs/designs/out-of-band-tenant-ddl.md
#
# Nothing here is mocked. The original design of this feature asserted that a warm
# pool holds a "baked search_path" and a schema cache of "dead table OIDs", so the
# next switch after an external pg_restore raises PG::UndefinedTable. Driving it
# against a real database refuted that: search_path is a NAME, re-resolved by the
# server per query. No double would have caught this, which is why these specs
# drive real PostgreSQL.
#
# What they pin is therefore mostly ABSENCE of breakage — the self-healing that lets
# us ship no eviction helper. If Rails or PostgreSQL ever changes this underneath us,
# these fail and we find out.
#
# PostgreSQL only: the refuted claim was PG-specific (search_path / OIDs), and PG
# schema-per-tenant is the strategy it was claimed against.
RSpec.describe('v4 out-of-band tenant DDL', :integration,
               skip: (V4_INTEGRATION_AVAILABLE && V4IntegrationHelper.postgresql? ? false : 'requires PostgreSQL')) do
  include V4IntegrationHelper

  let(:rand_suffix) { SecureRandom.hex(4) }
  let(:tenant)      { "acme_#{rand_suffix}" }
  let(:tenants)     { [tenant] }

  before do
    V4IntegrationHelper.ensure_test_database!
    @config = V4IntegrationHelper.establish_default_connection!

    Apartment.configure do |c|
      c.tenant_strategy   = :schema
      c.tenants_provider  = -> { tenants }
      c.default_tenant    = 'public'
      c.check_pending_migrations = false
    end
    Apartment.adapter = V4IntegrationHelper.build_adapter(@config)
    Apartment.activate!
    Apartment.adapter.create(tenant)
  end

  after do
    V4IntegrationHelper.cleanup_tenants!(tenants, Apartment.adapter)
    Apartment.clear_config
  end

  # A raw libpq connection: the external tool (a shell pg_restore), with no
  # ActiveRecord involvement whatsoever.
  def out_of_band(&)
    raw = PG.connect(
      host: @config['host'], port: @config['port'],
      user: @config['username'], password: @config['password'], dbname: @config['database']
    )
    yield(raw)
  ensure
    raw&.close
  end

  def backend_count
    out_of_band do |raw|
      raw.exec("SELECT count(*) FROM pg_stat_activity WHERE datname = '#{@config['database']}'")
        .first['count'].to_i
    end
  end

  def create_widgets!(columns = 'id bigserial primary key, name varchar')
    Apartment::Tenant.switch(tenant) do
      ActiveRecord::Base.connection.execute("CREATE TABLE widgets (#{columns})")
      ActiveRecord::Base.connection.execute("INSERT INTO widgets (name) VALUES ('original')")
    end
    Apartment.reset_tenant_pools!
  end

  def warm_pool!
    Apartment::Tenant.switch(tenant) do
      ActiveRecord::Base.connection.select_values('SELECT name FROM widgets')
      {
        pool: ActiveRecord::Base.connection_pool.object_id,
        pid: ActiveRecord::Base.connection.select_value('SELECT pg_backend_pid()'),
      }
    end
  end

  def tenant_pools_in_ar
    ActiveRecord::Base.connection_handler
      .connection_pool_list(:all)
      .select { |p| p.db_config.name.to_s.include?(tenant.to_s) }
  end

  describe 'a same-shape restore under a warm pool' do
    it 'self-heals: the warm connection reads the restored data, no eviction needed' do
      create_widgets!
      warm = warm_pool!

      out_of_band do |raw|
        raw.exec("DROP SCHEMA #{tenant} CASCADE")
        raw.exec("CREATE SCHEMA #{tenant}")
        raw.exec("CREATE TABLE #{tenant}.widgets (id bigserial primary key, name varchar)")
        raw.exec("INSERT INTO #{tenant}.widgets (name) VALUES ('restored')")
      end

      after = Apartment::Tenant.switch(tenant) do
        {
          rows: ActiveRecord::Base.connection.select_values('SELECT name FROM widgets'),
          pool: ActiveRecord::Base.connection_pool.object_id,
          pid: ActiveRecord::Base.connection.select_value('SELECT pg_backend_pid()'),
        }
      end

      # The same pool, on the same backend, sees the restored data. search_path is a
      # name the server re-resolves; nothing about the schema's identity was cached.
      expect(after[:rows]).to(eq(['restored']))
      expect(after[:pool]).to(eq(warm[:pool]))
      expect(after[:pid]).to(eq(warm[:pid]))
    end
  end

  describe 'a shape-changing restore under a warm pool' do
    it 'does not raise, and reload_schema_cache! is what refreshes the stale column list' do
      create_widgets!
      warm_pool!
      Apartment::Tenant.switch(tenant) { ActiveRecord::Base.connection_pool.schema_cache.columns('widgets') }

      out_of_band do |raw|
        raw.exec("DROP SCHEMA #{tenant} CASCADE")
        raw.exec("CREATE SCHEMA #{tenant}")
        raw.exec("CREATE TABLE #{tenant}.widgets (id bigserial primary key, name varchar, sku varchar)")
        raw.exec("INSERT INTO #{tenant}.widgets (name, sku) VALUES ('restored', 'SKU-1')")
      end

      stale = Apartment::Tenant.switch(tenant) do
        ActiveRecord::Base.connection_pool.schema_cache.columns('widgets').map(&:name)
      end
      expect(stale).to(eq(%w[id name])) # the drift: the pool has not seen `sku`

      # Queries still work despite the drift — the connection is not poisoned.
      expect(Apartment::Tenant.switch(tenant) do
        ActiveRecord::Base.connection.select_values('SELECT name FROM widgets')
      end).to(eq(['restored']))

      Apartment::Tenant.reload_schema_cache!(tenant)

      fresh = Apartment::Tenant.switch(tenant) do
        ActiveRecord::Base.connection_pool.schema_cache.columns('widgets').map(&:name)
      end
      expect(fresh).to(eq(%w[id name sku]))
    end
  end

  describe 'custom-type (enum) OID churn across a restore' do
    # The PG adapter caches type OIDs on the CONNECTION, and reload_schema_cache!
    # does not clear that map — so a recreated enum, which gets a NEW OID, is the
    # strongest candidate for permanently poisoning a warm connection. It does not.
    it 'self-heals: reads, filters and writes stay correct after the enum OID changes' do
      Apartment::Tenant.switch(tenant) do
        conn = ActiveRecord::Base.connection
        conn.execute("CREATE TYPE widget_status AS ENUM ('draft', 'live')")
        conn.execute('CREATE TABLE widgets (id bigserial primary key, name varchar, status widget_status)')
        conn.execute("INSERT INTO widgets (name, status) VALUES ('original', 'live')")
      end
      Apartment.reset_tenant_pools!

      model = Class.new(ActiveRecord::Base) do
        self.table_name = 'widgets'
        def self.name = 'Widget'
      end

      Apartment::Tenant.switch(tenant) { model.where(status: 'live').to_a } # warm the type map
      old_oid = out_of_band do |raw|
        raw.exec('SELECT t.oid FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace ' \
                 "WHERE n.nspname = '#{tenant}' AND t.typname = 'widget_status'").first['oid']
      end

      out_of_band do |raw|
        raw.exec("DROP SCHEMA #{tenant} CASCADE")
        raw.exec("CREATE SCHEMA #{tenant}")
        raw.exec("CREATE TYPE #{tenant}.widget_status AS ENUM ('draft', 'live')")
        raw.exec("CREATE TABLE #{tenant}.widgets (id bigserial primary key, name varchar, " \
                 "status #{tenant}.widget_status)")
        raw.exec("INSERT INTO #{tenant}.widgets (name, status) VALUES ('restored', 'live')")
      end

      new_oid = out_of_band do |raw|
        raw.exec('SELECT t.oid FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace ' \
                 "WHERE n.nspname = '#{tenant}' AND t.typname = 'widget_status'").first['oid']
      end
      expect(new_oid).not_to(eq(old_oid)) # the premise of the attack actually holds...

      # ...and the warm pool is fine anyway.
      Apartment::Tenant.switch(tenant) do
        expect(model.pluck(:status)).to(eq(['live']))
        expect(model.where(status: 'live').count).to(eq(1))
        expect(model.create!(name: 'post-restore', status: 'draft').status).to(eq('draft'))
      end
    end
  end

  describe 'Apartment.deregister_shard' do
    # Both halves of the old two-step were public, and each alone was wrong:
    # deregister-only wedged the tenant, remove-only leaked a live backend.
    # deregister_shard now does both, so neither state is reachable.
    it 'discards the pool whole: the tenant recovers, and no registration or backend leaks' do
      create_widgets!
      baseline = backend_count
      warm = warm_pool!
      expect(tenant_pools_in_ar.map(&:object_id)).to(include(warm[:pool]))

      Apartment.deregister_shard("#{tenant}:writing")

      # Forgotten by BOTH registries — this is what used to wedge the tenant.
      expect(Apartment.pool_manager.tracked?("#{tenant}:writing")).to(be(false))
      expect(tenant_pools_in_ar).to(be_empty)
      # And the old backend is gone — this is what used to leak.
      expect(backend_count).to(eq(baseline))

      # The tenant still works: the next switch builds a fresh pool.
      rebuilt = Apartment::Tenant.switch(tenant) do
        {
          rows: ActiveRecord::Base.connection.select_values('SELECT name FROM widgets'),
          pool: ActiveRecord::Base.connection_pool.object_id,
        }
      end
      expect(rebuilt[:rows]).to(eq(['original']))
      expect(rebuilt[:pool]).not_to(eq(warm[:pool]))
    end
  end
end
