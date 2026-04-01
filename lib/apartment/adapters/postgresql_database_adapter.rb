# frozen_string_literal: true

require_relative 'abstract_adapter'

module Apartment
  module Adapters
    # v4 PostgreSQL adapter using database-per-tenant isolation.
    #
    # Resolves tenant-specific connection configs by setting the `database` key
    # to the environmentified tenant name. Lifecycle operations (create/drop)
    # execute DDL against the default connection.
    class PostgresqlDatabaseAdapter < AbstractAdapter
      def resolve_connection_config(tenant, base_config: nil)
        config = base_config || send(:base_config)
        config.merge('database' => environmentify(tenant))
      end

      protected

      def create_tenant(tenant)
        db_name = environmentify(tenant)
        conn = ActiveRecord::Base.connection
        conn.execute(
          "CREATE DATABASE #{conn.quote_table_name(db_name)}"
        )
      rescue ActiveRecord::StatementInvalid => e
        raise unless e.cause.is_a?(PG::DuplicateDatabase)

        raise(Apartment::TenantExists, tenant)
      end

      def drop_tenant(tenant)
        db_name = environmentify(tenant)
        conn = ActiveRecord::Base.connection
        conn.execute(
          "DROP DATABASE IF EXISTS #{conn.quote_table_name(db_name)}"
        )
      end

      # grant_privileges: inherits no-op from AbstractAdapter.
      # Database-per-tenant RBAC grants require cross-database ordering
      # (GRANT CONNECT on server, table grants inside tenant DB).
      # Use the callable app_role escape hatch for this strategy.
      # See docs/designs/v4-phase5-rbac-roles-schema-cache.md.
    end
  end
end
