# frozen_string_literal: true

require 'spec_helper'
require_relative 'support'
require 'apartment/concerns/model'

RSpec.describe('v4 Pinned models integration (Apartment::Model)', :integration,
               skip: (V4_INTEGRATION_AVAILABLE ? false : 'requires ActiveRecord + database gem')) do
  include V4IntegrationHelper

  let(:tmp_dir) { Dir.mktmpdir('apartment_pinned') }
  let(:created_tenants) { [] }

  before do
    V4IntegrationHelper.ensure_test_database! unless V4IntegrationHelper.sqlite?
    config = V4IntegrationHelper.establish_default_connection!(tmp_dir: tmp_dir)

    # Create tables in default database
    ActiveRecord::Base.connection.create_table(:global_settings, force: true) do |t|
      t.string(:key)
      t.string(:value)
    end
    V4IntegrationHelper.create_test_table!

    # Simulate ApplicationRecord for realistic topology
    stub_const('ApplicationRecord', Class.new(ActiveRecord::Base) do
      self.abstract_class = true
    end)

    stub_const('GlobalSetting', Class.new(ApplicationRecord) do
      self.table_name = 'global_settings'
      include Apartment::Model

      pin_tenant
    end)

    stub_const('Widget', Class.new(ApplicationRecord) do
      self.table_name = 'widgets'
    end)

    Apartment.configure do |c|
      c.tenant_strategy = V4IntegrationHelper.tenant_strategy
      c.tenants_provider = -> { %w[tenant_a] }
      c.default_tenant = V4IntegrationHelper.default_tenant
      c.check_pending_migrations = false
    end

    Apartment.adapter = V4IntegrationHelper.build_adapter(config)
    Apartment.activate!
    Apartment.adapter.process_pinned_models

    Apartment.adapter.create('tenant_a')
    created_tenants << 'tenant_a'
    Apartment::Tenant.switch('tenant_a') do
      V4IntegrationHelper.create_test_table!('widgets', connection: ActiveRecord::Base.connection)
    end
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

  context 'pinned model connection routing' do
    it 'shares the tenant connection when shared_pinned_connection? is true' do
      if Apartment.adapter.shared_pinned_connection?
        expect(GlobalSetting.connection_specification_name).to(eq(ActiveRecord::Base.connection_specification_name))
      else
        skip 'adapter does not support shared pinned connections'
      end
    end

    it 'uses a separate connection when shared_pinned_connection? is false' do
      if Apartment.adapter.shared_pinned_connection?
        skip 'adapter supports shared pinned connections'
      else
        expect(GlobalSetting.connection_specification_name).not_to(eq(ActiveRecord::Base.connection_specification_name))
      end
    end
  end

  it 'pin_tenant is idempotent' do
    expect { Apartment.adapter.process_pinned_models }.not_to(raise_error)
    unless Apartment.adapter.shared_pinned_connection?
      expect(GlobalSetting.connection_specification_name).not_to(eq(ActiveRecord::Base.connection_specification_name))
    end
  end

  it 'pinned model queries always target the default database' do
    GlobalSetting.create!(key: 'site_name', value: 'TestSite')

    Apartment::Tenant.switch('tenant_a') do
      expect(GlobalSetting.count).to(eq(1))
      expect(GlobalSetting.first.key).to(eq('site_name'))
      expect(Widget.count).to(eq(0))
    end
  end

  it 'pinned model data persists across tenant switches' do
    GlobalSetting.create!(key: 'version', value: '1.0')

    Apartment::Tenant.switch('tenant_a') do
      expect(GlobalSetting.find_by(key: 'version').value).to(eq('1.0'))
    end

    expect(GlobalSetting.count).to(eq(1))
  end

  it 'pinned model writes inside a tenant block land in the default database' do
    Apartment::Tenant.switch('tenant_a') do
      GlobalSetting.create!(key: 'inside_tenant', value: 'yes')
    end

    expect(GlobalSetting.find_by(key: 'inside_tenant')).to(be_present)
  end

  it 'tenant model (Widget) still routes through tenant pool during switch' do
    Apartment::Tenant.switch('tenant_a') do
      Widget.create!(name: 'in_tenant')
      expect(Widget.count).to(eq(1))
    end

    # Back in default — tenant widget not visible (different database/schema)
    # For PG schema, public.widgets might exist; for DB-per-tenant, no widgets table in default
    if V4IntegrationHelper.postgresql?
      # Schema strategy: widgets table exists in public, should be empty
      expect(Widget.count).to(eq(0))
    end
  end

  context 'ApplicationRecord topology' do
    it 'normal models inheriting from ApplicationRecord get tenant routing' do
      Apartment::Tenant.switch('tenant_a') do
        Widget.create!(name: 'routed_correctly')
        expect(Widget.count).to(eq(1))
      end
    end
  end

  context 'transactional integrity (shared connection path)' do
    it 'rolls back both pinned and tenant model writes on transaction rollback' do
      skip 'requires shared_pinned_connection?' unless Apartment.adapter.shared_pinned_connection?

      Apartment::Tenant.switch('tenant_a') do
        ActiveRecord::Base.transaction do
          Widget.create!(name: 'will_be_rolled_back')
          GlobalSetting.create!(key: 'will_be_rolled_back', value: 'yes')
          raise ActiveRecord::Rollback
        end

        expect(Widget.count).to(eq(0))
        expect(GlobalSetting.where(key: 'will_be_rolled_back').count).to(eq(0))
      end
    end

    it 'commits both pinned and tenant model writes on successful transaction' do
      skip 'requires shared_pinned_connection?' unless Apartment.adapter.shared_pinned_connection?

      Apartment::Tenant.switch('tenant_a') do
        ActiveRecord::Base.transaction do
          Widget.create!(name: 'committed')
          GlobalSetting.create!(key: 'committed', value: 'yes')
        end

        expect(Widget.find_by(name: 'committed')).to(be_present)
        expect(GlobalSetting.find_by(key: 'committed')).to(be_present)
      end
    end
  end

  context 'STI subclass of pinned model' do
    before do
      stub_const('AdminSetting', Class.new(GlobalSetting))
    end

    it 'inherits pinned behavior' do
      AdminSetting.create!(key: 'admin_only', value: 'true')

      Apartment::Tenant.switch('tenant_a') do
        expect(AdminSetting.find_by(key: 'admin_only').value).to(eq('true'))
      end
    end
  end

  context 'deferred pin_tenant processing (table_name after pin_tenant)' do
    it 'qualifies explicit table_name declared after pin_tenant' do
      # Simulate the CampusESP pattern: pin_tenant above self.table_name.
      # Name the class first so establish_connection works on all adapters,
      # then drive process_pinned_model directly — the same call the TracePoint
      # triggers after the class body closes. The unit spec covers TracePoint
      # deferral; here we verify the qualification outcome with a real adapter.
      klass = Class.new(ApplicationRecord)
      stub_const('DeferredPinned', klass)
      klass.include(Apartment::Model)
      klass.table_name = 'global_settings'
      Apartment.process_pinned_model(klass)

      if Apartment.adapter.shared_pinned_connection?
        expect(DeferredPinned.table_name).to(end_with('.global_settings'))
      else
        expect(DeferredPinned.table_name).to(eq('global_settings'))
      end
    end

    it 'qualifies convention table_name with pin_tenant anywhere in body' do
      # Convention naming: no explicit self.table_name. Name first, then
      # include + process so the adapter sees the class name and can qualify.
      klass = Class.new(ApplicationRecord)
      stub_const('ConventionDeferred', klass)
      klass.include(Apartment::Model)
      Apartment.process_pinned_model(klass)

      expect(ConventionDeferred.table_name).to(include('.')) if Apartment.adapter.shared_pinned_connection?
    end
  end

  context 'config.excluded_models shim' do
    it 'still works via deprecated path' do
      # Re-setup with config.excluded_models instead of pin_tenant
      stub_const('LegacySetting', Class.new(ApplicationRecord) do
        self.table_name = 'global_settings'
      end)

      Apartment.clear_config
      config = V4IntegrationHelper.establish_default_connection!(tmp_dir: tmp_dir)

      Apartment.configure do |c|
        c.tenant_strategy = V4IntegrationHelper.tenant_strategy
        c.tenants_provider = -> { %w[tenant_a] }
        c.default_tenant = V4IntegrationHelper.default_tenant
        c.excluded_models = ['LegacySetting']
        c.check_pending_migrations = false
      end

      Apartment.adapter = V4IntegrationHelper.build_adapter(config)
      Apartment.activate!
      Apartment::Tenant.init

      expect(Apartment.pinned_models).to(include(LegacySetting))

      LegacySetting.create!(key: 'legacy', value: 'works')
      Apartment::Tenant.switch('tenant_a') do
        expect(LegacySetting.find_by(key: 'legacy').value).to(eq('works'))
      end
    end
  end

  sqlite_skip = V4_INTEGRATION_AVAILABLE && V4IntegrationHelper.sqlite? &&
                'SQLite single-writer lock causes BusyException'

  context 'concurrent pinned model access', :stress, skip: sqlite_skip do
    it 'two threads in different tenants both read/write the pinned model to default' do
      GlobalSetting.create!(key: 'shared', value: 'initial')

      threads = Array.new(2) do |i|
        Thread.new do # rubocop:disable ThreadSafety/NewThread
          Apartment::Tenant.switch('tenant_a') do
            GlobalSetting.create!(key: "thread_#{i}", value: "val_#{i}")
            sleep(0.01) # brief yield to increase interleaving
            GlobalSetting.find_by(key: "thread_#{i}")
          end
        end
      end

      threads.each(&:join)
      expect(GlobalSetting.count).to(eq(3)) # initial + 2 threads
    end
  end
end
