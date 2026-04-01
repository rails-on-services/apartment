# frozen_string_literal: true

require_relative 'abstract_adapter'

module Apartment
  module Adapters
    # v4 MySQL adapter using database-per-tenant isolation (mysql2 driver).
    #
    # Resolves tenant-specific connection configs by setting the `database` key
    # to the environmentified tenant name. Lifecycle operations (create/drop)
    # execute DDL against the default connection.
    class Mysql2Adapter < AbstractAdapter
      def resolve_connection_config(tenant, base_config: nil)
        config = base_config || send(:base_config)
        config.merge('database' => environmentify(tenant))
      end

      protected

      def create_tenant(tenant)
        db_name = environmentify(tenant)
        conn = ActiveRecord::Base.connection
        conn.execute("CREATE DATABASE IF NOT EXISTS #{conn.quote_table_name(db_name)}")
      end

      def drop_tenant(tenant)
        db_name = environmentify(tenant)
        conn = ActiveRecord::Base.connection
        conn.execute("DROP DATABASE IF EXISTS #{conn.quote_table_name(db_name)}")
      end

      private

      def grant_privileges(tenant, connection, role_name)
        db_name = environmentify(tenant)
        quoted_role = connection.quote(role_name)
        connection.execute(
          "GRANT SELECT, INSERT, UPDATE, DELETE ON `#{db_name}`.* TO #{quoted_role}@'%'"
        )
      end
    end
  end
end
