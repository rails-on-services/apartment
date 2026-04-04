# frozen_string_literal: true

require 'thor'

module Apartment
  class CLI < Thor
    class Tenants < Thor
      def self.exit_on_failure? = true
    end
  end
end
