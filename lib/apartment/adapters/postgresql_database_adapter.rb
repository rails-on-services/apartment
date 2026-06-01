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

      # The database-per-tenant missing-tenant error: connecting to a dropped
      # database raises ActiveRecord::NoDatabaseError (PG SQLSTATE 3D000) — an
      # unambiguous signal, unlike the schema strategy's 42P01. It surfaces raw at
      # query time, or wrapped in ApartmentError when ConnectionHandling resolves
      # the pool (the dev-mode pending-migration check), so both are listed;
      # #container_error? gates on the unwrapped NoDatabaseError.
      def failsafe_error_classes
        [ActiveRecord::NoDatabaseError, Apartment::ApartmentError]
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

      private

      def container_error?(error)
        error.is_a?(ActiveRecord::NoDatabaseError)
      end

      # Authoritative existence check on the DEFAULT connection: pg_database is a
      # cluster-global catalog reachable from any database, and the rescue runs
      # after switch restored Current.tenant to default. The tenant's database is
      # the environmentified name. A probe failure means we cannot prove it gone,
      # so report it as existing and let the original error re-raise.
      def tenant_container_exists?(tenant)
        conn = ActiveRecord::Base.connection
        quoted = conn.quote(environmentify(tenant))
        !conn.select_value("SELECT 1 FROM pg_database WHERE datname = #{quoted}").nil?
      rescue StandardError
        true
      end
    end
  end
end
