# frozen_string_literal: true

# lib/apartment/current.rb

require 'active_support/current_attributes'

module Apartment
  # https://api.rubyonrails.org/classes/ActiveSupport/CurrentAttributes.html
  class Current < ActiveSupport::CurrentAttributes
    attribute :adapter
  end
end
