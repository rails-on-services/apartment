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
        if klass.apartment_explicit_table_name?
          original = klass.table_name
          table = original.sub(/\A[^.]+\./, '')
          klass.table_name = "#{default_tenant}.#{table}"
          klass.apartment_mark_processed!(:explicit, original)
        else
          original_prefix = klass.table_name_prefix
          klass.table_name_prefix = "#{default_tenant}."
          klass.reset_table_name
          klass.apartment_mark_processed!(:convention, original_prefix)
        end
      end

      def resolve_connection_config(tenant, base_config: nil)
        config = base_config || send(:base_config)
        persistent = Apartment.config.postgres_config&.persistent_schemas || []
        search_path = [tenant, *persistent].map { |s| %("#{s}") }.join(',')

        config.merge('schema_search_path' => search_path)
      end

      # The schema-strategy missing-tenant error: a dropped schema is not caught
      # at switch time (search_path accepts a non-existent schema silently) — it
      # surfaces on the first query as ActiveRecord::StatementInvalid
      # (PG::UndefinedTable, 42P01). That is the same shape as a missing table in
      # a *live* schema, so #tenant_container_exists? does the disambiguating
      # to_regnamespace check.
      #
      # ApartmentError is included because ConnectionHandling wraps errors raised
      # during pool resolution (e.g. the dev-mode pending-migration check, which
      # queries schema_migrations in the gone schema) as ApartmentError with the
      # StatementInvalid as #cause; #container_error? then unwraps and classifies
      # it the same as the query-time case, and re-raises any other ApartmentError.
      def failsafe_error_classes
        [ActiveRecord::StatementInvalid, Apartment::ApartmentError]
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

      # Any StatementInvalid is a candidate; the authoritative call is the
      # existence probe below, so a missing table in a live schema (same 42P01)
      # correctly re-raises rather than 404ing.
      def container_error?(error)
        error.is_a?(ActiveRecord::StatementInvalid)
      end

      # Authoritative existence check, run on the DEFAULT connection: the
      # elevator's switch ensure-block has already restored Current.tenant before
      # the fail-safe rescue runs, so ActiveRecord::Base.connection targets the
      # default pool rather than the gone tenant. to_regnamespace returns NULL for
      # a missing schema. If the probe itself errors (e.g. the database is down),
      # we cannot prove the schema is gone — report it as existing so the original
      # error re-raises instead of masking infrastructure failure as a 404.
      def tenant_container_exists?(tenant)
        conn = ActiveRecord::Base.connection
        conn.select_value("SELECT to_regnamespace(#{conn.quote(tenant)}) IS NOT NULL")
      rescue StandardError
        true
      end

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
