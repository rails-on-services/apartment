# frozen_string_literal: true

require 'active_support/concern'

module Apartment
  # Re-establishes the request's tenant inside the OS thread that
  # ActionController::Live spawns for streaming responses. Auto-included
  # into ActionController::Live by the Apartment Railtie; every controller
  # that includes ActionController::Live picks up this around_action via
  # ActiveSupport::Concern composition.
  #
  # See docs/designs/rails-boundary-tenancy.md for the mechanism and why
  # an around_action (not a prepend on Live#process or new_controller_thread)
  # is the only correct hook on Rails < 8.1.2.
  module LiveTenancy
    extend ActiveSupport::Concern

    included do
      around_action :_apartment_with_live_tenant
    end

    private

    def _apartment_with_live_tenant(&)
      tenant = request.env[Apartment::ENV_TENANT_KEY]
      tenant ? Apartment::Tenant.switch(tenant, &) : yield
    end
  end
end
