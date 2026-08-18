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
      include PostgresqlTransactionState

      def shared_pinned_connection?
        !Apartment.config.force_separate_pinned_pool
      end

      # Pinned tables live in the default tenant's schema; every tenant
      # connection can reach them by schema-qualifying the name.
      def pinned_table_qualifier
        default_tenant
      end

      def resolve_connection_config(tenant, base_config: nil)
        config = base_config || send(:base_config)
        persistent = Apartment.config.postgres_config&.persistent_schemas || []
        search_path = [tenant, *persistent].map { |s| %("#{s}") }.join(',')

        config.merge('schema_search_path' => search_path)
      end

      # Schemas are named directly (never environmentified), so the physical
      # identifier validated at pool-resolution time is the raw tenant name.
      def physical_tenant_name(tenant)
        tenant.to_s
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

      # Role names are quoted with quote_column_name, not quote_table_name: the latter
      # splits on dots, so a legal role like `svc.migrator` becomes "svc"."migrator"
      # and `a.b.c` silently loses a segment. Neither is valid where one role
      # identifier is required, and role names never pass TenantNameValidator.
      # quoted_container stays as it is; container names do pass it, and it rejects dots.
      def standard_privilege_statements(ctx, grant_to:, include_functions: true)
        roles = Array(grant_to).map { |role| ctx.connection.quote_column_name(role) }.join(', ')
        schema = ctx.quoted_container

        case ctx.phase
        when :before_schema_load
          before_schema_load_statements(ctx, schema, roles, include_functions)
        when :after_schema_load
          [
            "GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA #{schema} TO #{roles}",
            "GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA #{schema} TO #{roles}",
          ]
        else
          # Contexts are gem-built, so an unknown phase is a gem bug. Raising beats
          # falling through to the after-phase statements, which would grant on
          # objects the caller may not have created yet.
          raise(Apartment::ConfigurationError, "Unknown privilege policy phase: #{ctx.phase.inspect}")
        end
      end

      # pg_get_userbyid-free: current_user is what ALTER DEFAULT PRIVILEGES scopes to
      # when FOR ROLE is omitted, so it is the role a policy must name to be explicit.
      def current_db_role(connection)
        connection.select_value('SELECT current_user')
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

      # FOR ROLE is explicit rather than implied by the executing role. Omitting it
      # is what let a rule be recorded under one role while tables were created
      # under another — see docs/designs/v4-rbac-contract.md.
      def before_schema_load_statements(ctx, schema, roles, include_functions)
        grantor = ctx.connection.quote_column_name(ctx.db_role)
        defaults = "ALTER DEFAULT PRIVILEGES FOR ROLE #{grantor} IN SCHEMA #{schema} GRANT"

        statements = [
          "GRANT USAGE ON SCHEMA #{schema} TO #{roles}",
          "#{defaults} SELECT, INSERT, UPDATE, DELETE ON TABLES TO #{roles}",
          "#{defaults} USAGE, SELECT ON SEQUENCES TO #{roles}",
        ]
        statements << "#{defaults} EXECUTE ON FUNCTIONS TO #{roles}" if include_functions
        statements
      end
    end
  end
end
