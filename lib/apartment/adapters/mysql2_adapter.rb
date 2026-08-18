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

      # Pinned tables live in the default tenant's database; every tenant
      # connection can reach them by database-qualifying the name.
      def pinned_table_qualifier
        base_config['database']
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

      # MySQL has no ALTER DEFAULT PRIVILEGES. `ON db.*` is pattern-based and covers
      # objects created later, so one statement in the first phase is the whole
      # policy and include_functions has nothing to control here.
      #
      # grant_to takes bare role names and every grant lands on `role@'%'`. Splitting
      # an account on its last @ would be wrong, because `me@localhost` is itself a
      # legal MySQL username, so a value carrying @ is refused rather than guessed at.
      # A specific host is what a custom policy is for.
      #
      # Branching on the phase by name, rather than falling out of a
      # before_schema_load? guard, so the empty after-phase is a stated decision and an
      # unrecognised phase raises. A silent nothing is the defect this whole design
      # replaces: app_role's String form did nothing on two adapters and told nobody.
      def standard_privilege_statements(ctx, grant_to:, include_functions: true) # rubocop:disable Lint/UnusedMethodArgument
        case ctx.phase
        when :before_schema_load
          roles = Array(grant_to)
          validate_bare_role_names!(roles)
          accounts = roles.map { |role| "#{ctx.connection.quote(role)}@'%'" }.join(', ')
          ["GRANT SELECT, INSERT, UPDATE, DELETE ON #{ctx.quoted_container}.* TO #{accounts}"]
        when :after_schema_load
          # Nothing to do: the grant above already covers tables the import and later
          # migrations create.
          []
        else
          raise(Apartment::ConfigurationError, "Unknown privilege policy phase: #{ctx.phase.inspect}")
        end
      end

      # Returns MySQL's `role@host` form, for a policy that needs to name the
      # executing account. The statement builder above does not consume it: it assumes
      # the `%` host, and MySQL's GRANT syntax wants the halves quoted separately
      # (`'role'@'host'`), which a whole `role@host` token cannot express.
      def current_db_role(connection)
        connection.select_value('SELECT CURRENT_USER()')
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

      def validate_bare_role_names!(roles)
        hosted = roles.grep(/@/)
        return if hosted.empty?

        raise(Apartment::ConfigurationError,
              "Apartment::Privileges.standard takes bare role names and grants to role@'%'. " \
              "Got: #{hosted.inspect}. Write a tenant_privilege_policy to grant to another host.")
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
