# frozen_string_literal: true

module Apartment
  module Patches
    # Prepended on ActionController::Live to propagate tenant context
    # into the thread spawned for streaming responses.
    #
    # ActionController::Live#new_controller_thread spawns a new thread (Thread B)
    # for the controller action. Under :fiber isolation, child fibers within
    # Thread B do not inherit CurrentAttributes from the parent fiber.
    # We store the tenant via thread_variable_set so the ConnectionHandling
    # fallback can resolve tenant context regardless of which fiber the query
    # runs on. (Thread#[] is fiber-local in Ruby 3.2+; thread_variable_set/get
    # is truly thread-scoped and visible across all fibers.)
    module LiveTenantPropagation
      def new_controller_thread
        tenant = Apartment::Current.tenant
        super do
          Thread.current.thread_variable_set(:apartment_current_tenant, tenant)
          yield
        ensure
          Thread.current.thread_variable_set(:apartment_current_tenant, nil)
        end
      end
    end
  end
end
