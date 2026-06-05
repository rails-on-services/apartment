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
      def shared_pinned_connection?
        !Apartment.config.force_separate_pinned_pool
      end

      def qualify_pinned_table_name(klass)
        db_name = base_config['database']

        if klass.apartment_explicit_table_name?
          original = klass.table_name
          table = original.sub(/\A[^.]+\./, '')
          klass.table_name = "#{db_name}.#{table}"
          klass.apartment_mark_processed!(:explicit, original)
        else
          original_prefix = klass.table_name_prefix
          klass.table_name_prefix = "#{db_name}."
          klass.reset_table_name
          klass.apartment_mark_processed!(:convention, original_prefix)
        end
      end

      def resolve_connection_config(tenant, base_config: nil)
        config = base_config || send(:base_config)
        config.merge('database' => environmentify(tenant))
      end

      # The database-per-tenant missing-tenant error: connecting to a dropped
      # database raises ActiveRecord::NoDatabaseError (MySQL error 1049) — an
      # unambiguous signal. It surfaces raw at query time, or wrapped in
      # ApartmentError when ConnectionHandling resolves the pool (the dev-mode
      # pending-migration check), so both are listed; #container_error? gates on
      # the unwrapped NoDatabaseError. Inherited by TrilogyAdapter.
      def failsafe_error_classes
        [ActiveRecord::NoDatabaseError, Apartment::ApartmentError]
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
          "GRANT SELECT, INSERT, UPDATE, DELETE ON #{connection.quote_table_name(db_name)}.* TO #{quoted_role}@'%'"
        )
      end

      def container_error?(error)
        error.is_a?(ActiveRecord::NoDatabaseError)
      end

      # Authoritative existence check on the DEFAULT connection:
      # information_schema.schemata is server-global and reachable from any
      # database, and the rescue runs after switch restored Current.tenant to
      # default. The tenant's database is the environmentified name. A probe
      # failure means we cannot prove it gone, so report it as existing and let
      # the original error re-raise.
      def tenant_container_exists?(tenant)
        conn = ActiveRecord::Base.connection
        quoted = conn.quote(environmentify(tenant))
        !conn.select_value("SELECT 1 FROM information_schema.schemata WHERE schema_name = #{quoted}").nil?
      rescue StandardError
        true
      end
    end
  end
end
