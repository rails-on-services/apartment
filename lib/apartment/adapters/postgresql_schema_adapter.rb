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
        conn = ActiveRecord::Base.connection
        conn.execute("CREATE SCHEMA #{conn.quote_table_name(tenant)}")
      end

      def drop_tenant(tenant)
        conn = ActiveRecord::Base.connection
        conn.execute("DROP SCHEMA #{conn.quote_table_name(tenant)} CASCADE")
      end
    end
  end
end
