# frozen_string_literal: true

# Shared RBAC test infrastructure for integration tests that verify
# role-aware connections, privilege grants, and Migrator migration_role.
#
# Usage: tag specs with :rbac plus :postgresql_only or :mysql_only.
# Roles are provisioned once per :rbac describe block via before(:context, :rbac).
# If provisioning fails (e.g., local PG user lacks CREATEROLE),
# all :rbac specs skip with an actionable message.
module RbacHelper
  ROLES = {
    db_manager: 'apt_test_db_manager',
    app_user: 'apt_test_app_user',
  }.freeze

  @provisioned = false
  @available = false

  module_function

  def provisioned?
    @provisioned
  end

  def available?
    @available
  end

  # Idempotent role creation. Engine-aware.
  # Returns true on success, false on failure.
  # One-shot: first failure wins for the process (no retry on subsequent :rbac contexts).
  def provision_roles!(connection)
    return @available if @provisioned

    @provisioned = true
    engine = V4IntegrationHelper.database_engine

    case engine
    when 'postgresql'
      provision_pg_roles!(connection)
    when 'mysql'
      provision_mysql_roles!(connection)
    else
      warn '[RbacHelper] RBAC tests require PostgreSQL or MySQL'
      return (@available = false)
    end

    @available = true
  rescue ActiveRecord::StatementInvalid => e
    if e.message.match?(/permission denied|must be superuser|CREATEROLE|Access denied/i)
      warn "[RbacHelper] Insufficient privileges to provision roles: #{e.message}"
    else
      warn "[RbacHelper] Unexpected error during role provisioning: #{e.message}"
    end
    warn '[RbacHelper] See docs/designs/v4-phase5.2-rbac-integration-tests.md for setup instructions.'
    @available = false
  end

  # Connect as a specific role. Stashes the original config for restoration.
  # For grant verification tests (separate connections, not SET ROLE).
  # Only stashes on first call — subsequent calls without restore reuse the original stash
  # to prevent overwriting the real config with an already-swapped one.
  def connect_as(role_key)
    username = ROLES.fetch(role_key)
    @stashed_config ||= ActiveRecord::Base.connection_db_config.configuration_hash.stringify_keys
    ActiveRecord::Base.establish_connection(@stashed_config.merge('username' => username))
  end

  # Restore the connection stashed by connect_as.
  # Clears the stash before reconnecting to prevent cross-test poisoning
  # if establish_connection raises.
  def restore_default_connection!
    return unless @stashed_config

    config = @stashed_config
    @stashed_config = nil
    ActiveRecord::Base.establish_connection(config)
  end

  # Register database configs for :writing and :db_manager roles with AR's
  # ConnectionHandler. Uses the same database but different usernames.
  # Must be called in before(:each), not before(:context): the :integration tag's
  # around hook swaps ConnectionHandler per example, discarding any registrations
  # made at the context level.
  def setup_connects_to!(base_config)
    handler = ActiveRecord::Base.connection_handler

    { writing: base_config,
      db_manager: base_config.merge('username' => ROLES[:db_manager]) }.each do |role, config|
      db_config = ActiveRecord::DatabaseConfigurations::HashConfig.new(
        'test', "primary_#{role}", config
      )
      handler.establish_connection(
        db_config,
        owner_name: ActiveRecord::Base,
        role: role
      )
    end
  end

  # Restore stashed connection if connect_as was called without restore.
  # Pool cleanup is handled by the ConnectionHandler swap in the :integration around hook.
  def teardown_rbac_connections!
    restore_default_connection! if @stashed_config
  end

  # --- Private provisioning methods ---

  def provision_pg_roles!(connection)
    connection.execute(<<~SQL.squish)
      DO $$
      BEGIN
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '#{ROLES[:db_manager]}') THEN
          CREATE ROLE #{ROLES[:db_manager]} LOGIN CREATEDB;
        END IF;
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '#{ROLES[:app_user]}') THEN
          CREATE ROLE #{ROLES[:app_user]} LOGIN;
        END IF;
      END $$;
    SQL
    connection.execute("GRANT #{ROLES[:app_user]} TO #{ROLES[:db_manager]}")
    # GRANT CREATE ON DATABASE so db_manager can create schemas.
    # This runs here (not in CI provisioning) because the test database
    # (apartment_v4_test) may not exist at CI role-provisioning time.
    # The CI database (apartment_postgresql_test) differs from the test database.
    db_name = connection.current_database
    connection.execute("GRANT CREATE ON DATABASE #{connection.quote_table_name(db_name)} TO #{ROLES[:db_manager]}")
    # db_manager needs full access to the public schema for migrate_primary
    # (which runs under migration_role). PG 15+ revoked CREATE ON SCHEMA public
    # FROM PUBLIC. We also need access to tables postgres creates (e.g.,
    # schema_migrations from non-RBAC specs that may run before or after
    # provisioning due to RSpec randomization).
    connection.execute("GRANT ALL ON SCHEMA public TO #{ROLES[:db_manager]}")
    connection.execute("GRANT ALL ON ALL TABLES IN SCHEMA public TO #{ROLES[:db_manager]}")
    connection.execute("GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO #{ROLES[:db_manager]}")
    # Cover tables/sequences created AFTER this provisioning runs. Without
    # FOR ROLE, applies to objects created later by the current session user
    # (typically 'postgres') in public.
    connection.execute(
      "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO #{ROLES[:db_manager]}"
    )
    connection.execute(
      "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO #{ROLES[:db_manager]}"
    )
  end

  def provision_mysql_roles!(connection)
    connection.execute("CREATE USER IF NOT EXISTS '#{ROLES[:db_manager]}'@'%'")
    connection.execute("CREATE USER IF NOT EXISTS '#{ROLES[:app_user]}'@'%'")
    connection.execute("GRANT ALL PRIVILEGES ON *.* TO '#{ROLES[:db_manager]}'@'%' WITH GRANT OPTION")
    # Wildcard grant is a safety net; the real per-tenant grants come from
    # Mysql2Adapter#grant_privileges during Apartment.adapter.create(tenant).
    connection.execute(
      "GRANT SELECT, INSERT, UPDATE, DELETE ON `apartment\\_%`.* TO '#{ROLES[:app_user]}'@'%'"
    )
    connection.execute('FLUSH PRIVILEGES')
  end

  private_class_method :provision_pg_roles!, :provision_mysql_roles!
end

# Wire up the :rbac tag to provision roles once per context.
if V4_INTEGRATION_AVAILABLE
  RSpec.configure do |config|
    config.before(:context, :rbac) do
      V4IntegrationHelper.ensure_test_database!
      V4IntegrationHelper.establish_default_connection!

      unless RbacHelper.provision_roles!(ActiveRecord::Base.connection)
        skip 'RBAC test roles not available. See docs/designs/v4-phase5.2-rbac-integration-tests.md'
      end
    end
  end
end
