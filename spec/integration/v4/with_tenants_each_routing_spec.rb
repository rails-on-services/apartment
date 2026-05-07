# frozen_string_literal: true

require 'spec_helper'
require_relative 'support'

# Reproducer for downstream report: PG::UndefinedTable raised inside
# Apartment::Tenant.with_tenants(...) { Apartment::Tenant.each { ... } }
# when the queried table exists only in tenant schemas (not public).
#
# Hypothesis under test: per-iteration switch in `each` correctly re-routes
# `connection_pool` to a pool whose db_config carries `schema_search_path`
# pointing at the iteration's tenant + persistent_schemas. If the gem is
# behaving as designed, the search_path observed during the iteration must
# include the tenant schema, and a query against a table that exists only
# in that schema must succeed.
#
# Run only against PostgreSQL — :schema strategy is PG-only.
RSpec.describe('v4 with_tenants + each routing', :integration,
               skip: (V4_INTEGRATION_AVAILABLE && V4IntegrationHelper.postgresql? ? false : 'requires PostgreSQL')) do
  include V4IntegrationHelper

  let(:tmp_dir)         { Dir.mktmpdir('apartment_with_tenants_each') }
  let(:created_tenants) { [] }
  let(:tenants)         { %w[parents test_tenant] }

  before do
    V4IntegrationHelper.ensure_test_database!
    config = V4IntegrationHelper.establish_default_connection!(tmp_dir: tmp_dir)

    ActiveRecord::Base.connection.execute('CREATE SCHEMA IF NOT EXISTS extensions')

    Apartment.configure do |c|
      c.tenant_strategy   = :schema
      c.tenants_provider  = -> { [] } # default empty; overridden via with_tenants
      c.default_tenant    = 'public'
      c.check_pending_migrations = false
      c.configure_postgres { |pg| pg.persistent_schemas = ['extensions'] }
    end

    Apartment.adapter = V4IntegrationHelper.build_adapter(config)
    Apartment.activate!

    tenants.each do |name|
      Apartment.adapter.create(name)
      created_tenants << name
      Apartment::Tenant.switch(name) do
        ActiveRecord::Base.connection.create_table(:forum_contents, force: true) do |t|
          t.string(:status)
          t.timestamps
        end
      end
    end
  end

  after do
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
    klass = Class.new(ActiveRecord::Base) { self.table_name = 'forum_contents' }
    stub_const('ForumContent', klass)

    counts = {}
    expect do
      Apartment::Tenant.with_tenants(*tenants) do
        Apartment::Tenant.each do |tenant|
          counts[tenant] = ForumContent.count
        end
      end
    end.not_to(raise_error)

    expect(counts.keys).to(eq(tenants))
    expect(counts.values).to(all(eq(0)))
  end

  it 'does the same when wrapped in an outer Tenant.switch (mirrors RSpec around hook)' do
    klass = Class.new(ActiveRecord::Base) { self.table_name = 'forum_contents' }
    stub_const('ForumContent', klass)

    expect do
      Apartment::Tenant.with_tenants(*tenants) do
        Apartment::Tenant.switch('test_tenant') do
          Apartment::Tenant.each { |_t| ForumContent.exists? }
        end
      end
    end.not_to(raise_error)
  end
end
