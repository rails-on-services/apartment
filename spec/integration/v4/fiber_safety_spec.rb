# frozen_string_literal: true

require 'spec_helper'
require_relative 'support'

RSpec.describe('v4 Fiber safety integration', :integration,
               skip: (V4_INTEGRATION_AVAILABLE ? false : 'requires ActiveRecord + database gem')) do
  include V4IntegrationHelper

  let(:tmp_dir) { Dir.mktmpdir('apartment_fiber') }
  let(:tenants) { %w[fiber_a fiber_b] }

  before do
    # v4 requires fiber isolation for CurrentAttributes to be fiber-local.
    @original_isolation_level = ActiveSupport::IsolatedExecutionState.isolation_level
    ActiveSupport::IsolatedExecutionState.isolation_level = :fiber

    V4IntegrationHelper.ensure_test_database! unless V4IntegrationHelper.sqlite?
    config = V4IntegrationHelper.establish_default_connection!(tmp_dir: tmp_dir)
    V4IntegrationHelper.create_test_table!

    stub_const('Widget', Class.new(ActiveRecord::Base) { self.table_name = 'widgets' })

    Apartment.configure do |c|
      c.tenant_strategy = V4IntegrationHelper.tenant_strategy
      c.tenants_provider = -> { tenants }
      c.default_tenant = V4IntegrationHelper.default_tenant
      c.check_pending_migrations = false
    end

    Apartment.adapter = V4IntegrationHelper.build_adapter(config)
    Apartment.activate!

    tenants.each do |t|
      Apartment.adapter.create(t)
      Apartment::Tenant.switch(t) do
        V4IntegrationHelper.create_test_table!('widgets', connection: ActiveRecord::Base.connection)
      end
    end
  end

  after do
    V4IntegrationHelper.cleanup_tenants!(tenants, Apartment.adapter)
    Apartment.clear_config
    Apartment::Current.reset
    ActiveSupport::IsolatedExecutionState.isolation_level = @original_isolation_level
    if V4IntegrationHelper.sqlite?
      ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
      FileUtils.rm_rf(tmp_dir)
    end
  end

  it 'isolates tenant state across fibers' do
    Apartment::Tenant.switch('fiber_a') do
      child_tenant = Fiber.new do
        Apartment::Tenant.switch('fiber_b') do
          Fiber.yield(Apartment::Tenant.current)
        end
      end

      child_result = child_tenant.resume
      expect(child_result).to(eq('fiber_b'))
      expect(Apartment::Tenant.current).to(eq('fiber_a'))
      expect(Apartment::Current.tenant).to(eq('fiber_a'))
    end
  end

  it 'preserves tenant across Fiber.yield/resume cycles' do
    fiber = Fiber.new do
      Apartment::Tenant.switch('fiber_a') do
        Fiber.yield(:switched)
        Apartment::Tenant.current
      end
    end

    expect(fiber.resume).to(eq(:switched))
    expect(fiber.resume).to(eq('fiber_a'))
  end

  it 'outer switch block unaffected by inner fiber switching' do
    Apartment::Tenant.switch('fiber_a') do
      Widget.create!(name: 'outer')

      fiber = Fiber.new do
        Apartment::Tenant.switch('fiber_b') do
          Widget.create!(name: 'inner')
          Apartment::Tenant.current
        end
      end

      inner_tenant = fiber.resume
      expect(inner_tenant).to(eq('fiber_b'))
      expect(Apartment::Tenant.current).to(eq('fiber_a'))
      expect(Widget.count).to(eq(1))
      expect(Widget.first.name).to(eq('outer'))
    end

    Apartment::Tenant.switch('fiber_b') do
      expect(Widget.count).to(eq(1))
      expect(Widget.first.name).to(eq('inner'))
    end
  end

  # Exercises scheduled fibers under a real Fiber::Scheduler implementation
  # (e.g., Falcon/async). On standard MRI, Fiber::Scheduler is an interface —
  # Fiber::Scheduler.new raises TypeError — so this skips via the in-body guard.
  context 'Fiber.scheduler integration' do
    it 'tenant state does not leak across scheduled fibers' do
      results = []
      mutex = Mutex.new

      scheduler = Fiber::Scheduler.new if defined?(Fiber::Scheduler)
      skip 'no built-in Fiber::Scheduler available' unless scheduler

      Fiber.set_scheduler(scheduler)

      Fiber.schedule do
        Apartment::Tenant.switch('fiber_a') do
          sleep(0.01) # yield to scheduler
          mutex.synchronize { results << { fiber: :a, tenant: Apartment::Tenant.current } }
        end
      end

      Fiber.schedule do
        Apartment::Tenant.switch('fiber_b') do
          sleep(0.01) # yield to scheduler
          mutex.synchronize { results << { fiber: :b, tenant: Apartment::Tenant.current } }
        end
      end

      Fiber.scheduler.close
      Fiber.set_scheduler(nil)

      a_result = results.find { |r| r[:fiber] == :a }
      b_result = results.find { |r| r[:fiber] == :b }

      expect(a_result).not_to(be_nil, 'Fiber A did not produce a result')
      expect(b_result).not_to(be_nil, 'Fiber B did not produce a result')
      expect(a_result[:tenant]).to(eq('fiber_a'))
      expect(b_result[:tenant]).to(eq('fiber_b'))
    end
  end

  # Smoke test: load_async under tenant context. On MRI/SQLite this typically
  # executes synchronously; the value is proving the tenant pool resolves correctly
  # when the load_async code path is exercised, not testing true async dispatch.
  context 'load_async integration',
          skip: (ActiveRecord::Relation.method_defined?(:load_async) ? false : 'requires load_async support') do
    it 'async relation resolves against the correct tenant pool' do
      Apartment::Tenant.switch('fiber_a') do
        Widget.create!(name: 'async_test')
      end

      Apartment::Tenant.switch('fiber_a') do
        relation = Widget.where(name: 'async_test').load_async
        # Force resolution
        results = relation.to_a
        expect(results.size).to(eq(1))
        expect(results.first.name).to(eq('async_test'))
      end

      # Verify it didn't leak into fiber_b
      Apartment::Tenant.switch('fiber_b') do
        expect(Widget.where(name: 'async_test').count).to(eq(0))
      end
    end
  end
end
