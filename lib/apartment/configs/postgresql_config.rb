# frozen_string_literal: true

module Apartment
  module Configs
    # PostgreSQL-specific configuration options.
    class PostgresqlConfig
      # Schemas that persist across all tenants (e.g., shared extensions).
      attr_accessor :persistent_schemas

      # Non-public schemas to include in schema dumps (e.g., %w[ext shared]).
      attr_accessor :include_schemas_in_dump

      def initialize
        @persistent_schemas = []
        @include_schemas_in_dump = []
      end

      # Validate persistent_schemas entries as PostgreSQL identifiers.
      # Same rules as tenant names: max 63 chars, valid PG identifier format.
      def validate!
        return if @persistent_schemas.blank?

        @persistent_schemas.each do |schema|
          TenantNameValidator.validate_common!(schema)
          TenantNameValidator.validate_postgresql_identifier!(schema)
        rescue ConfigurationError => e
          raise(ConfigurationError, "Invalid persistent_schema #{schema.inspect}: #{e.message}")
        end
      end

      # Freeze mutable collections, then freeze self.
      def freeze!
        @persistent_schemas.freeze
        @include_schemas_in_dump.freeze
        freeze
      end
    end
  end
end
