# frozen_string_literal: true

require 'spec_helper'
require_relative 'support'
require 'apartment/concerns/model'

# A subclass of a *concrete* pinned model can mean two opposite things, and
# until now the gem could not tell them apart — both inherit
# apartment_pinned? == true through the superclass walk, and neither is
# registered, because pin_tenant early-returns once any superclass is pinned.
#
#   A  STI child sharing the parent's table          -> global (works: reads base_class.table_name)
#   B  own table, calls pin_tenant, wants global     -> the silent no-op
#   C  own table, no pin_tenant, wants tenant data   -> must stay tenant-scoped
#
# B is an anti-pattern whose one real appearance is transitional: migrating an
# STI child off a pinned parent's table. That is also the worst moment for a
# silent failure, since the symptom looks like a botched backfill.
RSpec.describe('v4 pinned model subclasses', :integration,
               skip: (V4_INTEGRATION_AVAILABLE ? false : 'requires ActiveRecord + database gem')) do
  include V4IntegrationHelper

  let(:tmp_dir) { Dir.mktmpdir('apartment_pinned_subclass') }
  let(:created_tenants) { [] }
  # Overridden below to cover the separate-pool path, where pinned models are
  # routed to the default pool instead of being qualified onto the tenant pool.
  let(:separate_pinned_pool) { false }

  # Whether the engine under test shares the tenant connection for pinned
  # models (qualifying their table names) or gives them a separate pool.
  # PostgreSQL schema-per-tenant and MySQL share; SQLite file-per-tenant does
  # not. Derived from the engine the suite was launched with so it stays an
  # independent oracle — update alongside the scenario list, not by consulting
  # the adapter. See spec/integration/v4/scenarios/.
  def shared_pinned_engine?
    !V4IntegrationHelper.sqlite?
  end

  def build_tables!
    ActiveRecord::Base.connection.create_table(:settings, force: true) do |t|
      t.string(:label)
      t.string(:type)
    end
    ActiveRecord::Base.connection.create_table(:own_settings, force: true) { |t| t.string(:label) }
    Apartment::Tenant.switch('tenant_a') do
      ActiveRecord::Base.connection.create_table(:settings, force: true) do |t|
        t.string(:label)
        t.string(:type)
      end
      ActiveRecord::Base.connection.create_table(:own_settings, force: true) { |t| t.string(:label) }
    end
  end

  before do
    V4IntegrationHelper.ensure_test_database! unless V4IntegrationHelper.sqlite?
    config = V4IntegrationHelper.establish_default_connection!(tmp_dir: tmp_dir)

    stub_const('ApplicationRecord', Class.new(ActiveRecord::Base) { self.abstract_class = true })

    Apartment.configure do |c|
      c.tenant_strategy = V4IntegrationHelper.tenant_strategy
      c.tenants_provider = -> { %w[tenant_a] }
      c.default_tenant = V4IntegrationHelper.default_tenant
      c.check_pending_migrations = false
      c.force_separate_pinned_pool = separate_pinned_pool
    end
    Apartment.adapter = V4IntegrationHelper.build_adapter(config)
    Apartment.activate!

    Apartment.adapter.create('tenant_a')
    created_tenants << 'tenant_a'
    build_tables!

    stub_const('Setting', Class.new(ApplicationRecord) do
      self.table_name = 'settings'
      include Apartment::Model
    end)
    Setting.pin_tenant
    Apartment.process_pinned_model(Setting)
  end

  after do
    V4IntegrationHelper.cleanup_tenants!(created_tenants, Apartment.adapter)
    Apartment.clear_config
    Apartment::Current.reset
    if V4IntegrationHelper.sqlite?
      ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
      FileUtils.rm_rf(tmp_dir)
    end
  end

  context 'shape A — STI child sharing the parent table' do
    before { stub_const('StiSetting', Class.new(Setting)) }

    it 'follows the parent to the default tenant' do
      Setting.create!(label: 'default_row', type: 'StiSetting')
      Apartment::Tenant.switch('tenant_a') do
        expect(StiSetting.pluck(:label)).to(eq(['default_row']))
      end
    end
  end

  context 'shape B — own table, pin_tenant called, wants global data' do
    before do
      stub_const('OwnSetting', Class.new(Setting) do
        self.table_name = 'own_settings'
        include Apartment::Model
      end)
      OwnSetting.pin_tenant
      # pin_tenant defers via TracePoint(:end), which never fires for
      # Class.new, so process explicitly — as the docs instruct.
      Apartment.process_pinned_model(OwnSetting)

      stub_const('TenantOwnSetting', Class.new(ApplicationRecord) { self.table_name = 'own_settings' })
    end

    it 'is registered once pin_tenant is called on it' do
      expect(Apartment.pinned_models).to(include(OwnSetting))
    end

    it 'reads default-tenant rows from inside a tenant switch' do
      OwnSetting.create!(label: 'default_row')
      Apartment::Tenant.switch('tenant_a') do
        TenantOwnSetting.create!(label: 'tenant_row')
      end

      Apartment::Tenant.switch('tenant_a') do
        expect(OwnSetting.pluck(:label)).to(eq(['default_row']))
      end
    end
  end

  context 'shape C — own table, never pinned, must stay tenant-scoped' do
    before do
      stub_const('ScopedSetting', Class.new(Setting) { self.table_name = 'own_settings' })
      stub_const('DefaultOwnSetting', Class.new(ApplicationRecord) { self.table_name = 'own_settings' })
      stub_const('TenantOwnRow', Class.new(ApplicationRecord) { self.table_name = 'own_settings' })
    end

    it 'inherits the pin flag through the superclass walk' do
      expect(ScopedSetting.apartment_pinned?).to(be(true))
    end

    # CHARACTERIZATION, not a correctness guarantee: on shared-connection
    # engines C happens to get what it wants, and the separate-pool context
    # below records the opposite, which is wrong for C.
    #
    # The oracle is the ENGINE, deliberately not
    # `Apartment.adapter.shared_pinned_connection?`. Deriving it from the
    # production switch under test would let the example pass straight through
    # a regression in that switch, by flipping its own definition of correct
    # in lockstep with the behaviour.
    it 'reads tenant data on shared-connection engines (correct for C, by luck)' do
      skip 'engine routes pinned models to a separate pool' unless shared_pinned_engine?

      DefaultOwnSetting.create!(label: 'default_row')
      Apartment::Tenant.switch('tenant_a') do
        TenantOwnRow.create!(label: 'tenant_row')
      end

      Apartment::Tenant.switch('tenant_a') do
        expect(ScopedSetting.pluck(:label)).to(eq(['tenant_row']))
      end
    end
  end

  # The same three shapes with force_separate_pinned_pool, where pinned models
  # return the default pool from ConnectionHandling instead of being qualified
  # onto the tenant pool. Confirms whether the bug inverts between the paths.
  context 'with force_separate_pinned_pool' do
    let(:separate_pinned_pool) { true }

    it 'routes a pinned model to a separate connection' do
      expect(Apartment.adapter.shared_pinned_connection?).to(be(false))
    end

    it 'reads default-tenant rows for shape B' do
      stub_const('SepOwnSetting', Class.new(Setting) do
        self.table_name = 'own_settings'
        include Apartment::Model
      end)
      SepOwnSetting.pin_tenant
      # Without this the example would still pass — but for the wrong reason:
      # the inherited pin alone routes it to the default pool, so it would not
      # be exercising registration at all. TracePoint(:end) never fires for
      # Class.new, so nothing else would process it.
      Apartment.process_pinned_model(SepOwnSetting)
      expect(SepOwnSetting.apartment_pinned_processed?).to(be(true))

      stub_const('SepDefaultOwn', Class.new(ApplicationRecord) { self.table_name = 'own_settings' })

      SepDefaultOwn.create!(label: 'default_row')
      Apartment::Tenant.switch('tenant_a') do
        ActiveRecord::Base.connection.execute(
          "INSERT INTO own_settings (label) VALUES ('tenant_row')"
        )
      end

      Apartment::Tenant.switch('tenant_a') do
        expect(SepOwnSetting.pluck(:label)).to(eq(['default_row']))
      end
    end

    it 'also routes shape C to the default tenant, which is wrong for it' do
      stub_const('SepScopedSetting', Class.new(Setting) { self.table_name = 'own_settings' })
      stub_const('SepDefaultOwn2', Class.new(ApplicationRecord) { self.table_name = 'own_settings' })

      SepDefaultOwn2.create!(label: 'default_row')
      Apartment::Tenant.switch('tenant_a') do
        ActiveRecord::Base.connection.execute(
          "INSERT INTO own_settings (label) VALUES ('tenant_row')"
        )
      end

      Apartment::Tenant.switch('tenant_a') do
        expect(SepScopedSetting.pluck(:label)).to(eq(['default_row']))
      end
    end
  end
end
