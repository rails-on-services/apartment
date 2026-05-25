# frozen_string_literal: true

require 'spec_helper'
require_relative 'support'

# Executable documentation of the silent-default-pool failure mode that
# docs/designs/apartment-v4.md "Async query correctness" describes.
#
# When Apartment::Current.tenant is nil, ConnectionHandling#connection_pool
# falls through to the default-tenant pool. That's correct for explicit
# no-tenant code, but it's also the same path that fires when tenant
# context was lost across a thread/fiber boundary -- a lazy AR
# association accessed after its switch block exited, or a load_async
# relation consumed outside the original switch.
#
# This spec demonstrates the failure mode end-to-end on sqlite3 with
# planted distinguishing data (`in_acme` in tenant 'acme', `in_default`
# in the default tenant). Without the spec, the doc section is just
# prose; with it, the contract is enforceable as a regression test and
# the failure shape is reproducible for anyone debugging a suspected
# silent-fallback leak.
#
# Provenance: this spec was salvaged from PR #417 (closed). #417 also
# shipped an opt-in debug-level diagnostic flag to log every fallback;
# the flag was closed because adoption required workflow plumbing
# (CI gate or post-session log triage) that we don't have. The spec
# survives because it has standalone value as the executable
# demonstration of the bug class.
RSpec.describe('v4 async query correctness', :integration,
               skip: (V4_INTEGRATION_AVAILABLE ? false : 'requires ActiveRecord + database gem')) do
  include V4IntegrationHelper

  let(:tmp_dir) { Dir.mktmpdir('apartment_async_correctness') }
  let(:tenants) { %w[acme] }

  before do
    V4IntegrationHelper.ensure_test_database! unless V4IntegrationHelper.sqlite?
    @connection_config = V4IntegrationHelper.establish_default_connection!(tmp_dir: tmp_dir)
    stub_const('Widget', Class.new(ActiveRecord::Base) { self.table_name = 'widgets' })

    Apartment.configure do |c|
      c.tenant_strategy = V4IntegrationHelper.tenant_strategy
      c.tenants_provider = -> { tenants }
      c.default_tenant = V4IntegrationHelper.default_tenant
      c.check_pending_migrations = false
    end
    Apartment.adapter = V4IntegrationHelper.build_adapter(@connection_config)
    Apartment.activate!

    tenants.each { |t| Apartment.adapter.create(t) }
    V4IntegrationHelper.create_test_table!
    Widget.create!(name: 'in_default')

    tenants.each do |t|
      Apartment::Tenant.switch(t) do
        V4IntegrationHelper.create_test_table!('widgets', connection: ActiveRecord::Base.connection)
        Widget.create!(name: "in_#{t}")
      end
    end
  end

  after do
    V4IntegrationHelper.cleanup_tenants!(tenants, Apartment.adapter) if Apartment.adapter
    Apartment.clear_config
    Apartment::Current.reset
    ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:') if V4IntegrationHelper.sqlite?
    FileUtils.rm_rf(tmp_dir)
  end

  # The failure case. A relation captured inside Tenant.switch('acme')
  # carries the tenant scope at schedule time; consuming it after the
  # block exits re-resolves connection_pool on the consumer fiber where
  # Current.tenant is nil, falls through to super, and runs against the
  # default tenant. No error, wrong data. This is what tenant-leak bugs
  # actually look like.
  it 'silently returns the DEFAULT tenant data when a captured relation is consumed outside its switch block' do
    captured = Apartment::Tenant.switch('acme') { Widget.all }

    names = captured.pluck(:name)
    expect(names).to(eq(['in_default']))
    expect(names).not_to(include('in_acme'))
  end

  # The contract. Consume the relation inside the same switch block
  # that scheduled it. Both the main query and any lazy/preload paths
  # resolve connection_pool with tenant context intact.
  it 'returns the TENANT data when the same relation is consumed inside its switch block' do
    Apartment::Tenant.switch('acme') do
      expect(Widget.pluck(:name)).to(eq(['in_acme']))
    end
  end
end
