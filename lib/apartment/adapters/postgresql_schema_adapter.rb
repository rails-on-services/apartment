# frozen_string_literal: true

require_relative 'abstract_adapter'

module Apartment
  module Adapters
    # v4 PostgreSQL adapter using schema-based tenant isolation.
    #
    # Resolves tenant-specific connection configs by setting `schema_search_path`
    # to the tenant schema plus any persistent schemas from PostgreSQLConfig.
    # Lifecycle operations (create/drop) execute DDL against the default connection.
    class PostgreSQLSchemaAdapter < AbstractAdapter
      def resolve_connection_config(tenant)
        persistent = Apartment.config.postgres_config&.persistent_schemas || []
        search_path = [tenant, *persistent].join(',')

        base_config.merge('schema_search_path' => search_path)
      end

      protected

      def create_tenant(tenant)
        ActiveRecord::Base.connection.execute(
          "CREATE SCHEMA #{ActiveRecord::Base.connection.quote_table_name(tenant)}"
        )
      end

      def drop_tenant(tenant)
        ActiveRecord::Base.connection.execute(
          "DROP SCHEMA #{ActiveRecord::Base.connection.quote_table_name(tenant)} CASCADE"
        )
      end

      private

      def base_config
        connection_config.transform_keys(&:to_s)
      end
    end
  end
end
