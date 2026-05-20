# frozen_string_literal: true

require 'active_support/current_attributes'

module Apartment
  # Fiber-safe tenant context using ActiveSupport::CurrentAttributes.
  # Replaces the v3 Thread.current[:apartment_adapter] approach.
  #
  # Do not call the bare +reset+ on this class from domain or lifecycle
  # methods. +reset+ clears every attribute, so adding one here silently
  # widens the blast radius of every existing call site. +reset+ belongs at
  # true execution boundaries only: the Rails executor clears it once per
  # request; a test suite clears it in an +after+ hook. Inside domain code,
  # assign the specific attributes you mean to clear.
  class Current < ActiveSupport::CurrentAttributes
    attribute :tenant, :previous_tenant, :migrating, :tenant_override
  end
end
