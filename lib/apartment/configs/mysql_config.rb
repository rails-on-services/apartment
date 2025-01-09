# frozen_string_literal: true

# lib/apartment/configs/mysql_config.rb

module Apartment
  # Mysql specific configuration options for Apartment.
  module Configs
    class MysqlConfig
      # Switch databases using `use` instead of re-establishing the connection.
      # @!attribute [rw] use_database_switching
      # @return [Boolean] true if `use` should be used, defaults to false
      attr_accessor :use_database_switching

      def initialize
        @use_database_switching = false
      end

      # Validates the configuration.
      # @raise [ConfigurationError] if the configuration is invalid
      def validate!
        # Do nothing for now
      end
    end
  end
end
