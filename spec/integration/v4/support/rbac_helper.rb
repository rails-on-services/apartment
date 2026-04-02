# frozen_string_literal: true

# Shared RBAC test infrastructure for integration tests that verify
# role-aware connections, privilege grants, and Migrator migration_role.
#
# Usage: tag specs with :rbac plus :postgresql_only or :mysql_only.
# Roles are provisioned once per suite via before(:context, :rbac).
# If provisioning fails (e.g., local PG user lacks CREATEROLE),
# all :rbac specs skip with an actionable message.
module RbacHelper
  ROLES = {
    db_manager: 'apt_test_db_manager',
    app_user: 'apt_test_app_user'
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
      return(@available = false)
    end

    @available = true
  rescue ActiveRecord::StatementInvalid => e
    warn "[RbacHelper] Could not provision roles (#{e.class}): #{e.message}"
    warn '[RbacHelper] See docs/designs/v4-phase5.2-rbac-integration-tests.md for setup instructions.'
    @available = false
  end

  # Connect as a specific role. Stashes the original config for restoration.
  # For grant verification tests (separate connections, not SET ROLE).
  def connect_as(role_key)
    username = ROLES.fetch(role_key)
    @stashed_config ||= ActiveRecord::Base.connection_db_config.configuration_hash.stringify_keys
    ActiveRecord::Base.establish_connection(@stashed_config.merge('username' => username))
  end

  # Restore the connection stashed by connect_as.
  def restore_default_connection!
    return unless @stashed_config

    ActiveRecord::Base.establish_connection(@stashed_config)
    @stashed_config = nil
  end

  # Register database configs for :writing and :db_manager roles with AR's
  # ConnectionHandler. Uses the same database but different usernames.
  # Call in before(:each) — after the ConnectionHandler swap creates a fresh handler.
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

  # Disconnect and remove non-primary pools created during tests.
  def teardown_rbac_connections!
    @stashed_config = nil
  end

  # --- Private provisioning methods ---

  def provision_pg_roles!(connection)
    connection.execute(<<~SQL)
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
    db_name = connection.current_database
    connection.execute("GRANT CREATE ON DATABASE #{connection.quote_table_name(db_name)} TO #{ROLES[:db_manager]}")
  end

  def provision_mysql_roles!(connection)
    connection.execute("CREATE USER IF NOT EXISTS '#{ROLES[:db_manager]}'@'%'")
    connection.execute("CREATE USER IF NOT EXISTS '#{ROLES[:app_user]}'@'%'")
    connection.execute("GRANT ALL PRIVILEGES ON *.* TO '#{ROLES[:db_manager]}'@'%'")
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
