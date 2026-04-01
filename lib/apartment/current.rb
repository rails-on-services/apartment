# frozen_string_literal: true

require 'active_support/current_attributes'

module Apartment
  # Fiber-safe tenant context using ActiveSupport::CurrentAttributes.
  # Replaces the v3 Thread.current[:apartment_adapter] approach.
  class Current < ActiveSupport::CurrentAttributes
    attribute :tenant, :previous_tenant, :migrating
  end
end
