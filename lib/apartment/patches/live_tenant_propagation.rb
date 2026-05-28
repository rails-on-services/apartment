# frozen_string_literal: true

require 'active_support/isolated_execution_state'

module Apartment
  module Patches
    # Backports rails/rails#56902 ("Pass IsolatedExecutionState.context to
    # share_with") to Rails versions where the fix has not landed.
    #
    # On Rails 7.2 / 8.0 / 8.1.x stable, ActionController::Live#process calls
    # ActiveSupport::IsolatedExecutionState.share_with(Thread.current, ...)
    # which reads from Thread.current.active_support_execution_state. Under
    # :fiber isolation that's empty — the data lives on Fiber.current's
    # accessor. The spawned thread's root fiber starts with empty state and
    # any CurrentAttributes set on the request fiber are invisible inside
    # response.stream.write — silent cross-tenant data exposure.
    #
    # The fix: before Live#process spawns the streaming thread, point
    # Thread.current.active_support_execution_state at the same hash
    # Fiber.current.active_support_execution_state points at. share_with's
    # shallow .dup then copies the right data into the spawned thread's
    # root fiber. Restore Thread's prior state on exit.
    #
    # Mechanically equivalent to what rails/rails#56902 does on main:
    # capture IsolatedExecutionState.context (= Fiber.current under :fiber)
    # and pass it to share_with. Apartment can't edit Rails source from
    # inside a gem, but a temporary mirror feeds share_with the right
    # pointer with the same end result.
    #
    # No-op under :thread isolation (Rails' own propagation already works
    # there). No-op when Fiber.current.active_support_execution_state is
    # nil (no CurrentAttributes have been touched on this fiber yet, so
    # there is nothing to propagate).
    #
    # See docs/designs/rails-boundary-tenancy.md.
    module LiveTenantPropagation
      def process(name)
        return super unless ActiveSupport::IsolatedExecutionState.isolation_level == :fiber

        fiber_state = Fiber.current.active_support_execution_state
        return super if fiber_state.nil?

        previous_thread_state = Thread.current.active_support_execution_state
        Thread.current.active_support_execution_state = fiber_state
        begin
          super
        ensure
          Thread.current.active_support_execution_state = previous_thread_state
        end
      end
    end
  end
end
