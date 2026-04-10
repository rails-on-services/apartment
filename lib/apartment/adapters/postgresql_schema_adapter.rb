# frozen_string_literal: true

require_relative 'abstract_adapter'

module Apartment
  module Adapters
    # v4 PostgreSQL adapter using schema-based tenant isolation.
    #
    # Resolves tenant-specific connection configs by setting `schema_search_path`
    # to the raw tenant name (not environmentified — schemas are named directly,
    # unlike database-per-tenant adapters) plus any persistent schemas from
    # Apartment.config.postgres_config. Lifecycle operations (create/drop)
    # execute DDL against the default connection.
    class PostgresqlSchemaAdapter < AbstractAdapter
      def shared_pinned_connection?
        !Apartment.config.force_separate_pinned_pool
      end

      def qualify_pinned_table_name(klass)
        if explicit_table_name?(klass)
          klass.instance_variable_set(:@apartment_original_table_name, klass.table_name)
          klass.instance_variable_set(:@apartment_qualification_path, :explicit)
          table = klass.table_name.sub(/\A[^.]+\./, '')
          klass.table_name = "#{default_tenant}.#{table}"
        else
          klass.instance_variable_set(:@apartment_qualification_path, :convention)
          klass.table_name_prefix = "#{default_tenant}."
          klass.reset_table_name
        end
      end

      def resolve_connection_config(tenant, base_config: nil)
        config = base_config || send(:base_config)
        persistent = Apartment.config.postgres_config&.persistent_schemas || []
        search_path = [tenant, *persistent].map { |s| %("#{s}") }.join(',')

        config.merge('schema_search_path' => search_path)
      end

      protected

      def create_tenant(tenant)
        conn = ActiveRecord::Base.connection
        conn.execute("CREATE SCHEMA IF NOT EXISTS #{conn.quote_table_name(tenant)}")
      end

      def drop_tenant(tenant)
        conn = ActiveRecord::Base.connection
        conn.execute("DROP SCHEMA IF EXISTS #{conn.quote_table_name(tenant)} CASCADE")
      end

      private

      def grant_privileges(tenant, connection, role_name) # rubocop:disable Metrics/MethodLength
        quoted_schema = connection.quote_table_name(tenant)
        quoted_role = connection.quote_table_name(role_name)

        connection.execute("GRANT USAGE ON SCHEMA #{quoted_schema} TO #{quoted_role}")
        connection.execute(
          "GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA #{quoted_schema} TO #{quoted_role}"
        )
        connection.execute(
          "GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA #{quoted_schema} TO #{quoted_role}"
        )
        connection.execute(
          "ALTER DEFAULT PRIVILEGES IN SCHEMA #{quoted_schema} " \
          "GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO #{quoted_role}"
        )
        connection.execute(
          "ALTER DEFAULT PRIVILEGES IN SCHEMA #{quoted_schema} " \
          "GRANT USAGE, SELECT ON SEQUENCES TO #{quoted_role}"
        )
        connection.execute(
          "ALTER DEFAULT PRIVILEGES IN SCHEMA #{quoted_schema} " \
          "GRANT EXECUTE ON FUNCTIONS TO #{quoted_role}"
        )
      end
    end
  end
end
