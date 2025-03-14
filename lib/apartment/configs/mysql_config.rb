# frozen_string_literal: true

# lib/apartment/configs/mysql_config.rb

module Apartment
  # Mysql specific configuration options for Apartment.
  module Configs
    class MySQLConfig
      def initialize; end

      # Validates the configuration.
      # @raise [ConfigurationError] if the configuration is invalid
      def validate!
        # Do nothing for now
      end
    end
  end
end
