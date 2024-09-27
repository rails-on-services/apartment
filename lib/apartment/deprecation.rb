# frozen_string_literal: true

require 'active_support/deprecation'

module Apartment
  DEPRECATOR = ActiveSupport::Deprecation.new(Apartment::VERSION, 'Apartment')
end
