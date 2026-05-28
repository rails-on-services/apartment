# frozen_string_literal: true

require 'spec_helper'
require 'active_support/isolated_execution_state'
require 'apartment/patches/live_tenant_propagation'

RSpec.describe(Apartment::Patches::LiveTenantPropagation) do
  # Stand-in for ActionController::Live: a Module with #process that we can
  # prepend the patch onto, and a Class that includes it so we can dispatch.
  let(:base_module) do
    Module.new do
      def self.name
        'LiveStub'
      end

      attr_accessor :captured_thread_state

      def process(_name)
        # Record what Thread.current.active_support_execution_state looks like
        # at the moment super(name) would normally run share_with against it.
        self.captured_thread_state = Thread.current.active_support_execution_state
      end
    end
  end

  let(:controller_class) do
    klass = Class.new
    mod = base_module
    mod.prepend(described_class)
    klass.include(mod)
    klass
  end

  let(:original_isolation_level) { ActiveSupport::IsolatedExecutionState.isolation_level }

  around do |example|
    example.run
  ensure
    ActiveSupport::IsolatedExecutionState.isolation_level = original_isolation_level
    Thread.current.active_support_execution_state = nil
    Fiber.current.active_support_execution_state = nil
  end

  context 'under :fiber isolation with populated fiber state' do
    before do
      ActiveSupport::IsolatedExecutionState.isolation_level = :fiber
      Fiber.current.active_support_execution_state = { tenant: 'acme' }
      Thread.current.active_support_execution_state = nil
    end

    it 'mirrors Fiber.current.active_support_execution_state onto Thread.current during super (identity, not eq)' do
      instance = controller_class.new
      fiber_hash = Fiber.current.active_support_execution_state
      instance.process(:show)
      # Identity check: the captured Thread state must be the SAME object the
      # Fiber held, not just equal. That is what `share_with`'s shallow dup
      # would read on the real Live spawn path.
      expect(instance.captured_thread_state).to(equal(fiber_hash))
    end

    it "restores Thread.current's prior state after super" do
      Thread.current.active_support_execution_state = { prior: true }

      controller_class.new.process(:show)

      expect(Thread.current.active_support_execution_state).to(eq({ prior: true }))
    end

    it 'restores even when super raises' do
      Thread.current.active_support_execution_state = { prior: true }
      raising_module = Module.new do
        def process(_name)
          raise('boom from super')
        end
      end
      raising_module.prepend(described_class)

      klass = Class.new
      klass.include(raising_module)

      expect { klass.new.process(:show) }.to(raise_error('boom from super'))
      expect(Thread.current.active_support_execution_state).to(eq({ prior: true }))
    end
  end

  context 'under :thread isolation' do
    before do
      ActiveSupport::IsolatedExecutionState.isolation_level = :thread
      Thread.current.active_support_execution_state = { tenant: 'acme' }
    end

    it 'is a no-op: Thread state is what Rails reads from, no mirroring needed' do
      original = Thread.current.active_support_execution_state
      instance = controller_class.new
      instance.process(:show)
      expect(Thread.current.active_support_execution_state).to(equal(original))
      expect(instance.captured_thread_state).to(equal(original))
    end
  end

  context 'when fiber state is nil (no CurrentAttributes touched in this fiber)' do
    before do
      ActiveSupport::IsolatedExecutionState.isolation_level = :fiber
      Fiber.current.active_support_execution_state = nil
    end

    it 'falls through to super without touching Thread state' do
      Thread.current.active_support_execution_state = { prior: true }
      controller_class.new.process(:show)
      expect(Thread.current.active_support_execution_state).to(eq({ prior: true }))
    end
  end
end
