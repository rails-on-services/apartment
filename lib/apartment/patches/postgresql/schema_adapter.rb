# frozen_string_literal: true

# lib/apartment/patches/postgresql/schema_adapter.rb

# This patch is meant to remove any schema_prefix apart from the ones for
# excluded models. The schema_prefix would be resolved by Apartment's setting
# of search path
module Apartment
  module Patches
    module Postgresql
      module SchemaAdapter
        def default_sequence_name(table, _column)
          result = super
          schema_prefix = "#{sequence_schema(result)}."

          # Handle excluded models
          if excluded_model?(table)
            result = ensure_default_tenant_prefix(result, schema_prefix)
          else
            # Remove schema_prefix for non-excluded models
            result&.delete_prefix!(schema_prefix)
          end

          result
        end

        private

        # Ensures the sequence uses the default tenant prefix for excluded models
        def ensure_default_tenant_prefix(sequence_name, schema_prefix)
          default_prefix = "#{Apartment::Tenant.default_tenant}."

          unless sequence_name&.starts_with?(default_prefix)
            sequence_name&.delete_prefix!(schema_prefix)
            sequence_name = default_prefix + sequence_name
          end

          sequence_name
        end

        # Determines the schema prefix for a sequence name
        def sequence_schema(sequence_name)
          current_schemas = Apartment::Tenant.current
          return current_schemas unless current_schemas.is_a?(Array)

          current_schemas.find { |schema| sequence_name.starts_with?("#{schema}.") }
        end

        # Checks if a table belongs to an excluded model
        def excluded_model?(table)
          Apartment.excluded_models.any? { |model| model.constantize.table_name == table }
        end
      end
    end
  end
end

ActiveSupport.on_load(:active_record_postgresqladapter) do
  prepend Apartment::Patches::Postgresql::SchemaAdapter
end
