# frozen_string_literal: true

require 'spec_helper'
require_relative 'support'

# End-to-end proof of the failure mode strict_tenant_lookup is designed to
# catch: a relation captured inside Tenant.switch and accessed afterwards
# silently re-resolves connection_pool on the consumer thread. With
# Current.tenant.nil?, ConnectionHandling#connection_pool falls through to
# super and the query runs against the DEFAULT tenant's data -- no error,
# wrong data. With strict_tenant_lookup ON, the same path raises loudly.
#
# This is the consumer-thread re-resolution case documented in
# docs/designs/apartment-v4.md "Async query correctness". The exact same
# mechanism backs lazy associations after load_async (relation.first.user
# triggers an exec_queries on the consumer thread).
RSpec.describe('strict_tenant_lookup integration', :integration,
               skip: (V4_INTEGRATION_AVAILABLE ? false : 'requires ActiveRecord + database gem')) do
  include V4IntegrationHelper

  let(:tmp_dir) { Dir.mktmpdir('apartment_strict') }
  let(:tenants) { %w[acme] }

  before do
    V4IntegrationHelper.ensure_test_database! unless V4IntegrationHelper.sqlite?
    @connection_config = V4IntegrationHelper.establish_default_connection!(tmp_dir: tmp_dir)
    stub_const('Widget', Class.new(ActiveRecord::Base) { self.table_name = 'widgets' })
  end

  after do
    V4IntegrationHelper.cleanup_tenants!(tenants, Apartment.adapter) if Apartment.adapter
    Apartment.clear_config
    Apartment::Current.reset
    ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:') if V4IntegrationHelper.sqlite?
    FileUtils.rm_rf(tmp_dir)
  end

  # Plant 'in_default' in the default tenant and "in_<name>" in each tenant
  # so the failure-mode test can prove WHICH tenant the silent fallback hit.
  def populate_data(strict_mode:)
    Apartment.configure do |c|
      c.tenant_strategy = V4IntegrationHelper.tenant_strategy
      c.tenants_provider = -> { tenants }
      c.default_tenant = V4IntegrationHelper.default_tenant
      c.check_pending_migrations = false
      c.strict_tenant_lookup = strict_mode
    end
    Apartment.adapter = V4IntegrationHelper.build_adapter(@connection_config)
    Apartment.activate!

    # Under strict mode, every connection_pool call needs an explicit tenant
    # in context. Wrap default-tenant setup in switch(default_tenant) so the
    # same setup path works in both modes.
    Apartment::Tenant.switch(V4IntegrationHelper.default_tenant) do
      tenants.each { |t| Apartment.adapter.create(t) }
      V4IntegrationHelper.create_test_table!
      Widget.create!(name: 'in_default')
    end

    tenants.each do |t|
      Apartment::Tenant.switch(t) do
        V4IntegrationHelper.create_test_table!('widgets', connection: ActiveRecord::Base.connection)
        Widget.create!(name: "in_#{t}")
      end
    end
  end

  context 'without strict_tenant_lookup (current default in production)' do
    before { populate_data(strict_mode: false) }

    it 'silently returns the default tenant data when a captured relation is accessed outside its switch block' do
      captured = Apartment::Tenant.switch('acme') { Widget.all }

      # Outside the switch, Apartment::Current.tenant is nil. captured.pluck
      # triggers exec_queries -> connection_pool -> the prepend falls through
      # to super -> default-tenant pool. The query returns 'in_default'
      # instead of 'in_acme'. No error. This is the failure mode.
      names = captured.pluck(:name)
      expect(names).to(eq(['in_default']))
      expect(names).not_to(include('in_acme'))
    end

    it 'returns the tenant data when the same relation is accessed inside its switch' do
      Apartment::Tenant.switch('acme') do
        expect(Widget.pluck(:name)).to(eq(['in_acme']))
      end
    end
  end

  context 'with strict_tenant_lookup' do
    before { populate_data(strict_mode: true) }

    it 'raises ImplicitDefaultTenant when a captured relation is accessed outside its switch block' do
      captured = Apartment::Tenant.switch('acme') { Widget.all }

      expect { captured.pluck(:name) }.to(raise_error(Apartment::ImplicitDefaultTenant))
    end

    it 'does not interfere when the same relation is accessed inside its switch' do
      Apartment::Tenant.switch('acme') do
        expect(Widget.pluck(:name)).to(eq(['in_acme']))
      end
    end

    it 'does not interfere with explicit default-tenant access' do
      Apartment::Tenant.switch(V4IntegrationHelper.default_tenant) do
        expect(Widget.pluck(:name)).to(eq(['in_default']))
      end
    end

    # End-to-end proof of the Migrator exemption. With strict_tenant_lookup ON,
    # Migrator#migrate_primary's AR::Base.connection_pool.migration_context call
    # (line 100 in lib/apartment/migrator.rb) would raise without the
    # Current.migrating bypass. Use migration_context directly inside a
    # Current.migrating block to exercise the same path that migrate_primary
    # takes; running the full Migrator under sqlite would also need a
    # db/migrate directory which the integration suite doesn't ship.
    it 'allows Migrator-style nil-tenant default-pool access when Current.migrating is set' do
      Apartment::Current.migrating = true
      expect { ActiveRecord::Base.connection_pool.migration_context }.not_to(raise_error)
    ensure
      Apartment::Current.migrating = false
    end
  end
end
