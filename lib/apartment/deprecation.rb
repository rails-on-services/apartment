# frozen_string_literal: true

# lib/apartment/deprecation.rb

require 'active_support/deprecation'
require_relative 'version'

module Apartment
  DEPRECATOR = ActiveSupport::Deprecation.new(Apartment::VERSION, 'Apartment')
end
