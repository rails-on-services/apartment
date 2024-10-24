# frozen_string_literal: true

require 'yaml'

module Apartment
  module Test
    def self.config
      @config ||= YAML.safe_load(ERB.new(File.read('spec/config/database.yml')).result)
    end
  end
end
