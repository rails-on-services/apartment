# frozen_string_literal: true

module Apartment
  module Configs
    # PostgreSQL-specific configuration options.
    class PostgreSQLConfig
      # Schemas that persist across all tenants (e.g., shared extensions).
      attr_accessor :persistent_schemas

      # Whether to verify search_path resets to default after switching away from a tenant.
      attr_accessor :enforce_search_path_reset

      # Non-public schemas to include in schema dumps (e.g., %w[ext shared]).
      attr_accessor :include_schemas_in_dump

      def initialize
        @persistent_schemas = []
        @enforce_search_path_reset = false
        @include_schemas_in_dump = []
      end
    end
  end
end
