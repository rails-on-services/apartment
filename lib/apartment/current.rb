# frozen_string_literal: true

# lib/apartment/current.rb

require 'active_support/current_attributes'

module Apartment
  # Thread-isolated attributes for Apartment
  # I.e., each thread will have its own current tenant
  # https://api.rubyonrails.org/classes/ActiveSupport/CurrentAttributes.html
  class Current < ActiveSupport::CurrentAttributes
    attribute :tenant
  end
end
