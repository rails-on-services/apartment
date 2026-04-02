# frozen_string_literal: true

require 'spec_helper'
require_relative 'support'
require_relative 'support/rbac_helper'

unless defined?(Rails)
  module Rails
    def self.env
      'test'
    end
  end
end

RSpec.describe('PostgreSQL database-per-tenant callable app_role', :integration, :postgresql_only, :rbac,
               skip: (V4_INTEGRATION_AVAILABLE && V4IntegrationHelper.postgresql? ? false : 'requires PG')) do
  include V4IntegrationHelper

  let(:tenant) { 'apt_db_rbac_tenant' }

  # Force-drop a PG database by terminating active connections first.
  def force_drop_database(db_name)
    conn = ActiveRecord::Base.connection
    conn.execute(<<~SQL.squish)
      SELECT pg_terminate_backend(pid)
      FROM pg_stat_activity
      WHERE datname = #{conn.quote(db_name)} AND pid <> pg_backend_pid()
    SQL
    conn.execute("DROP DATABASE IF EXISTS #{conn.quote_table_name(db_name)}")
  rescue ActiveRecord::StatementInvalid, ActiveRecord::ConnectionNotEstablished => e
    warn "force_drop_database(#{db_name}): #{e.class}: #{e.message}"
  end

  before do
    V4IntegrationHelper.ensure_test_database!
    @config = V4IntegrationHelper.establish_default_connection!
    RbacHelper.setup_connects_to!(@config)

    force_drop_database(tenant)

    # Callable app_role: logs the call, then switches into the tenant DB to
    # issue grants. For database-per-tenant PG, grant_tenant_privileges runs
    # on the default DB connection — the callable must Tenant.switch to reach
    # the tenant database's public schema.
    @grant_log = []
    callable = lambda { |t, conn|
      @grant_log << { tenant: t, user: conn.execute('SELECT current_user AS cu').first['cu'] }
      Apartment::Tenant.switch(t) do
        tc = ActiveRecord::Base.connection
        role = tc.quote_table_name(RbacHelper::ROLES[:app_user])
        # Tables: DML access
        tc.execute("GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO #{role}")
        tc.execute(
          "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO #{role}"
        )
        # Sequences: needed for serial/identity columns (INSERT calls nextval)
        tc.execute("GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO #{role}")
        tc.execute("ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO #{role}")
      end
    }

    Apartment.configure do |c|
      c.tenant_strategy = :database_name
      c.tenants_provider = -> { [tenant] }
      c.default_tenant = @config['database']
      c.app_role = callable
      c.check_pending_migrations = false
    end

    require 'apartment/adapters/postgresql_database_adapter'
    Apartment.adapter = Apartment::Adapters::PostgresqlDatabaseAdapter.new(
      @config.transform_keys(&:to_sym)
    )
    Apartment.activate!

    # Create tenant under :db_manager role (production pattern via connects_to).
    # This creates pool "tenant:db_manager" with db_manager credentials.
    ActiveRecord::Base.connected_to(role: :db_manager) do
      Apartment.adapter.create(tenant)
    end

    # Revoke DDL from PUBLIC in the tenant DB. Runs as :writing role (postgres/
    # superuser) which creates a SEPARATE pool "tenant:writing" — no collision
    # with the db_manager pool cached above.
    # db_manager can't REVOKE because it doesn't own the public schema
    # (inherited from template1, owned by postgres).
    Apartment::Tenant.switch(tenant) do
      ActiveRecord::Base.connection.execute('REVOKE CREATE ON SCHEMA public FROM PUBLIC')
    end

    # Create a test table as db_manager inside the tenant database.
    ActiveRecord::Base.connected_to(role: :db_manager) do
      Apartment::Tenant.switch(tenant) do
        ActiveRecord::Base.connection.execute(<<~SQL.squish)
          CREATE TABLE widgets (id serial PRIMARY KEY, name varchar(255))
        SQL
      end
    end
  end

  after do
    RbacHelper.teardown_rbac_connections!
    ActiveRecord::Base.connection_handler.clear_all_connections!
    ActiveRecord::Base.establish_connection(@config)
    force_drop_database(tenant)
    Apartment.clear_config
    Apartment::Current.reset
  end

  it 'invokes the callable with tenant name and a live connection' do
    expect(@grant_log.size).to(eq(1))
    expect(@grant_log.first[:tenant]).to(eq(tenant))
    expect(@grant_log.first[:user]).to(be_a(String))
  end

  it 'app_user can DML on tables in the tenant database' do
    RbacHelper.connect_as(:app_user, 'database' => tenant)
    conn = ActiveRecord::Base.connection
    conn.execute("INSERT INTO widgets (name) VALUES ('test')")
    val = conn.select_value('SELECT name FROM widgets')
    expect(val).to(eq('test'))
  ensure
    RbacHelper.restore_default_connection!
  end

  it 'app_user cannot CREATE TABLE in the tenant database' do
    RbacHelper.connect_as(:app_user, 'database' => tenant)
    expect do
      ActiveRecord::Base.connection.execute('CREATE TABLE forbidden (id serial)')
    end.to(raise_error(ActiveRecord::StatementInvalid, /permission denied/))
  ensure
    RbacHelper.restore_default_connection!
  end

  it 'app_user can DML on tables created after initial grants (default privileges)' do
    # db_manager creates a new table after tenant creation
    ActiveRecord::Base.connected_to(role: :db_manager) do
      Apartment::Tenant.switch(tenant) do
        ActiveRecord::Base.connection.execute(<<~SQL.squish)
          CREATE TABLE gadgets (id serial PRIMARY KEY, label varchar(255))
        SQL
      end
    end

    # app_user can DML on the new table via ALTER DEFAULT PRIVILEGES
    RbacHelper.connect_as(:app_user, 'database' => tenant)
    conn = ActiveRecord::Base.connection
    conn.execute("INSERT INTO gadgets (label) VALUES ('shiny')")
    val = conn.select_value('SELECT label FROM gadgets')
    expect(val).to(eq('shiny'))
  ensure
    RbacHelper.restore_default_connection!
  end
end
