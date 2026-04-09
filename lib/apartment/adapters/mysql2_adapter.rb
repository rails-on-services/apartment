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
      # MySQL supports cross-database queries on the same server connection
      # (e.g. default_db.delayed_jobs from any USE database context).
      def shared_connection_supported?
        true
      end

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

      # Qualify with the actual default database name from base_config
      # (e.g. "apartment_v4_test.delayed_jobs").
      def qualify_pinned_table_name(klass)
        table = klass.table_name.split('.').last
        klass.table_name = "#{base_config['database']}.#{table}"
      end

      def grant_privileges(tenant, connection, role_name)
        db_name = environmentify(tenant)
        quoted_role = connection.quote(role_name)
        connection.execute(
          "GRANT SELECT, INSERT, UPDATE, DELETE ON #{connection.quote_table_name(db_name)}.* TO #{quoted_role}@'%'"
        )
      end
    end
  end
end
