# frozen_string_literal: true

# lib/apartment/configs/postgres_config.rb

module Apartment
  # Postgres specific configuration options for Apartment.
  module Configs
    class PostgreSQLConfig
      # Specifies schemas that will always remain in the search_path when switching or resetting tenants.
      # @!attribute [rw] persistent_schemas
      # @return [Array<String>] a list of schemas to keep in the search_path, defaults to an empty array
      attr_accessor :persistent_schemas

      # Specifies whether to enforce a search_path reset when checking in a connection.
      # @!attribute [rw] enforce_search_path_reset
      # @return [Boolean] whether to enforce a search_path reset when checking in a connection, defaults to false
      attr_accessor :enforce_search_path_reset

      def initialize
        @persistent_schemas = []
        @enforce_search_path_reset = false
      end

      # Validates the configuration.
      # @raise [ConfigurationError] if the configuration is invalid
      def validate!
        # Do nothing for now
      end

      def apply!
        return unless enforce_search_path_reset

        ActiveRecord::ConnectionAdapters::PostgreSQLAdapter.set_callback(:checkin, :before) do |conn|
          next if /"?public"?/.match?(conn.instance_variable_get(:@schema_search_path))

          conn.execute('RESET search_path')
        end
      end
    end
  end
end
