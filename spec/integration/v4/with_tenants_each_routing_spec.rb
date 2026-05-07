# frozen_string_literal: true

require 'spec_helper'
require_relative 'support'

# :schema strategy is PG-only — gated to PostgreSQL.
RSpec.describe('v4 with_tenants + each routing', :integration, # rubocop:disable RSpec/MultipleMemoizedHelpers
               skip: (V4_INTEGRATION_AVAILABLE && V4IntegrationHelper.postgresql? ? false : 'requires PostgreSQL')) do
  include V4IntegrationHelper

  let(:tmp_dir)         { Dir.mktmpdir('apartment_with_tenants_each') }
  let(:created_tenants) { [] }
  # Random suffix avoids collisions with leftover schemas/tables from prior
  # local runs. CI is fresh per run, but local dev DBs accumulate state.
  let(:rand_suffix)         { SecureRandom.hex(4) }
  let(:tenants)             { ["acme_#{rand_suffix}", "globex_#{rand_suffix}"] }
  let(:table_name)          { "widgets_#{rand_suffix}" }
  let(:default_tenant_name) { 'public' }

  before do
    V4IntegrationHelper.ensure_test_database!
    config = V4IntegrationHelper.establish_default_connection!(tmp_dir: tmp_dir)

    ActiveRecord::Base.connection.execute('CREATE SCHEMA IF NOT EXISTS extensions')

    Apartment.configure do |c|
      c.tenant_strategy   = :schema
      c.tenants_provider  = -> { [] }
      c.default_tenant    = default_tenant_name
      c.check_pending_migrations = false
      c.configure_postgres { |pg| pg.persistent_schemas = ['extensions'] }
    end

    Apartment.adapter = V4IntegrationHelper.build_adapter(config)
    Apartment.activate!

    tenants.each do |name|
      Apartment.adapter.create(name)
      created_tenants << name
      Apartment::Tenant.switch(name) do
        V4IntegrationHelper.create_test_table!(table_name)
      end
    end

    # Hard precondition: the test table must live only in tenant schemas,
    # never in the default-tenant schema. If it leaks there, the routing
    # assertions below pass by accident — a query under a fallback search_path
    # that includes the default tenant resolves the table from there.
    leaked = ActiveRecord::Base.connection.select_value(<<~SQL.squish)
      SELECT 1 FROM information_schema.tables
      WHERE table_schema = #{ActiveRecord::Base.connection.quote(default_tenant_name)}
        AND table_name = #{ActiveRecord::Base.connection.quote(table_name)}
    SQL
    raise("#{table_name} leaked into default tenant '#{default_tenant_name}'; reproducer invalid") if leaked
  end

  after do
    ActiveRecord::Base.connection.execute('DROP SCHEMA IF EXISTS extensions CASCADE')
  ensure
    V4IntegrationHelper.cleanup_tenants!(created_tenants, Apartment.adapter)
    Apartment.clear_config
    Apartment::Current.reset
  end

  it 'sets search_path to the iterating tenant on each pass' do
    seen = []
    Apartment::Tenant.with_tenants(*tenants) do
      Apartment::Tenant.each do |tenant|
        sp = ActiveRecord::Base.connection.select_value('SHOW search_path').to_s
        seen << [tenant, sp]
      end
    end

    expect(seen.map(&:first)).to(eq(tenants))
    seen.each do |tenant, sp|
      expect(sp).to(include(tenant), "expected search_path for iteration '#{tenant}' to include it; got #{sp.inspect}")
      expect(sp).to(include('extensions'))
    end
  end

  it 'resolves a tenant-only table during each (no PG::UndefinedTable)' do
    klass = Class.new(ActiveRecord::Base)
    klass.table_name = table_name
    stub_const('Widget', klass)

    counts = {}
    expect do
      Apartment::Tenant.with_tenants(*tenants) do
        Apartment::Tenant.each do |tenant|
          counts[tenant] = Widget.count
        end
      end
    end.not_to(raise_error)

    expect(counts.keys).to(eq(tenants))
    expect(counts.values).to(all(eq(0)))
  end

  it 'resolves tenant-only tables when an outer Tenant.switch wraps with_tenants + each (RSpec around-hook shape)' do
    klass = Class.new(ActiveRecord::Base)
    klass.table_name = table_name
    stub_const('Widget', klass)

    expect do
      Apartment::Tenant.switch(tenants.last) do
        Apartment::Tenant.with_tenants(*tenants) do
          Apartment::Tenant.each { |_t| Widget.exists? }
        end
      end
    end.not_to(raise_error)
  end

  it 'routes correctly when the override is a callable' do
    klass = Class.new(ActiveRecord::Base)
    klass.table_name = table_name
    stub_const('Widget', klass)

    visited = []
    Apartment::Tenant.with_tenants_provider(-> { tenants.dup }) do
      Apartment::Tenant.each do |t|
        visited << t
        Widget.count
      end
    end

    expect(visited).to(eq(tenants))
  end

  it 'restores tenant_override even when each raises mid-iteration' do
    expect do
      Apartment::Tenant.with_tenants(*tenants) do
        Apartment::Tenant.each { |_t| raise('boom') } # rubocop:disable Lint/UnreachableLoop
      end
    end.to(raise_error('boom'))

    expect(Apartment::Current.tenant_override).to(be_nil)
    expect(Apartment::Current.tenant).to(be_nil)
  end

  context 'under a non-default role' do # rubocop:disable RSpec/MultipleMemoizedHelpers
    before do
      reading_config = V4IntegrationHelper.default_connection_config(tmp_dir: tmp_dir)
      db_config = ActiveRecord::DatabaseConfigurations::HashConfig.new(
        'test', 'primary_reading', reading_config
      )
      ActiveRecord::Base.connection_handler.establish_connection(
        db_config,
        owner_name: ActiveRecord::Base,
        role: :reading
      )
    end

    it 'keys per-tenant pools by the active role and routes search_path correctly' do
      klass = Class.new(ActiveRecord::Base)
      klass.table_name = table_name
      stub_const('Widget', klass)

      seen = {}
      counts = {}
      ActiveRecord::Base.connected_to(role: :reading) do
        Apartment::Tenant.with_tenants(*tenants) do
          Apartment::Tenant.each do |t|
            seen[t] = ActiveRecord::Base.connection.select_value('SHOW search_path').to_s
            counts[t] = Widget.count
          end
        end
      end

      expect(seen.keys).to(eq(tenants))
      seen.each { |t, sp| expect(sp).to(include(t)) }
      expect(counts.values).to(all(eq(0)))

      pool_keys = Apartment.pool_manager.stats[:tenants]
      tenants.each { |t| expect(pool_keys).to(include("#{t}:reading")) }
    end
  end

  context 'with a non-default default_tenant configured' do # rubocop:disable RSpec/MultipleMemoizedHelpers
    let(:default_tenant_name) { "wte_root_#{SecureRandom.hex(4)}" }

    before do
      ActiveRecord::Base.connection.execute(
        "CREATE SCHEMA IF NOT EXISTS #{ActiveRecord::Base.connection.quote_table_name(default_tenant_name)}"
      )
    end

    after do
      ActiveRecord::Base.connection.execute(
        "DROP SCHEMA IF EXISTS #{ActiveRecord::Base.connection.quote_table_name(default_tenant_name)} CASCADE"
      )
    end

    it 'honors the configured default_tenant in routing and the precondition' do
      expect(Apartment.config.default_tenant).to(eq(default_tenant_name))

      seen = {}
      Apartment::Tenant.with_tenants(*tenants) do
        Apartment::Tenant.each do |t|
          seen[t] = ActiveRecord::Base.connection.select_value('SHOW search_path').to_s
        end
      end

      expect(seen.keys).to(eq(tenants))
      seen.each do |t, sp|
        expect(sp).to(include(t))
        # The default tenant is NOT public here; the search_path under each
        # iteration must not depend on PG's public-by-default behavior.
        expect(sp).not_to(include(default_tenant_name))
      end
    end
  end
end
