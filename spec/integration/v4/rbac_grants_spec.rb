# frozen_string_literal: true

require 'spec_helper'
require_relative 'support'
require_relative 'support/rbac_helper'

RSpec.describe('PostgreSQL RBAC privilege grants', :integration, :postgresql_only, :rbac,
               skip: (V4_INTEGRATION_AVAILABLE && V4IntegrationHelper.postgresql? ? false : 'requires PG')) do
  include V4IntegrationHelper

  let(:tenant) { 'rbac_grants_tenant' }

  before do
    config = V4IntegrationHelper.establish_default_connection!

    # Create tenant as db_manager (owns the schema) with app_role grants
    RbacHelper.connect_as(:db_manager)

    Apartment.configure do |c|
      c.tenant_strategy = :schema
      c.tenants_provider = -> { [tenant] }
      c.default_tenant = 'public'
      c.app_role = RbacHelper::ROLES[:app_user]
      c.check_pending_migrations = false
    end

    Apartment.adapter = V4IntegrationHelper.build_adapter(
      config.merge('username' => RbacHelper::ROLES[:db_manager])
    )
    Apartment.activate!
    Apartment.adapter.create(tenant)

    # Create a test table as db_manager (inside the tenant schema)
    Apartment::Tenant.switch(tenant) do
      ActiveRecord::Base.connection.execute(<<~SQL.squish)
        CREATE TABLE #{ActiveRecord::Base.connection.quote_table_name(tenant)}.widgets (
          id serial PRIMARY KEY,
          name varchar(255)
        )
      SQL
    end

    RbacHelper.restore_default_connection!
  end

  after do
    # Reconnect as default (superuser) to drop
    V4IntegrationHelper.establish_default_connection!
    Apartment.adapter = V4IntegrationHelper.build_adapter(
      V4IntegrationHelper.default_connection_config
    )
    V4IntegrationHelper.cleanup_tenants!([tenant], Apartment.adapter)
    Apartment.clear_config
    Apartment::Current.reset
    RbacHelper.teardown_rbac_connections!
  end

  context 'as app_user' do
    before { RbacHelper.connect_as(:app_user) }
    after  { RbacHelper.restore_default_connection! }

    it 'can SELECT, INSERT, UPDATE, DELETE' do
      conn = ActiveRecord::Base.connection
      conn.execute("INSERT INTO #{conn.quote_table_name(tenant)}.widgets (name) VALUES ('test')")

      result = conn.execute("SELECT name FROM #{conn.quote_table_name(tenant)}.widgets")
      expect(result.first['name']).to(eq('test'))

      conn.execute("UPDATE #{conn.quote_table_name(tenant)}.widgets SET name = 'updated'")

      result = conn.execute("SELECT name FROM #{conn.quote_table_name(tenant)}.widgets")
      expect(result.first['name']).to(eq('updated'))

      conn.execute("DELETE FROM #{conn.quote_table_name(tenant)}.widgets")
      result = conn.execute("SELECT count(*) AS c FROM #{conn.quote_table_name(tenant)}.widgets")
      expect(result.first['c'].to_i).to(eq(0))
    end

    it 'cannot CREATE TABLE in the tenant schema' do
      expect do
        ActiveRecord::Base.connection.execute(
          "CREATE TABLE #{ActiveRecord::Base.connection.quote_table_name(tenant)}.forbidden (id serial)"
        )
      end.to(raise_error(ActiveRecord::StatementInvalid, /permission denied/))
    end

    it 'cannot DROP SCHEMA' do
      expect do
        ActiveRecord::Base.connection.execute(
          "DROP SCHEMA #{ActiveRecord::Base.connection.quote_table_name(tenant)} CASCADE"
        )
      end.to(raise_error(ActiveRecord::StatementInvalid, /must be owner|permission denied/))
    end
  end

  context 'ALTER DEFAULT PRIVILEGES' do
    it 'grants DML on tables created after initial tenant creation' do
      # As db_manager: create a new table after the tenant was created
      RbacHelper.connect_as(:db_manager)
      ActiveRecord::Base.connection.execute(<<~SQL.squish)
        CREATE TABLE #{ActiveRecord::Base.connection.quote_table_name(tenant)}.gadgets (
          id serial PRIMARY KEY,
          label varchar(255)
        )
      SQL
      RbacHelper.restore_default_connection!

      # As app_user: verify DML works on the new table
      RbacHelper.connect_as(:app_user)
      conn = ActiveRecord::Base.connection
      conn.execute("INSERT INTO #{conn.quote_table_name(tenant)}.gadgets (label) VALUES ('shiny')")
      result = conn.execute("SELECT label FROM #{conn.quote_table_name(tenant)}.gadgets")
      expect(result.first['label']).to(eq('shiny'))
    ensure
      RbacHelper.restore_default_connection!
    end
  end

  context 'function execute grant' do
    it 'app_user can execute functions created by db_manager' do
      # db_manager creates a function in the tenant schema
      RbacHelper.connect_as(:db_manager)
      conn = ActiveRecord::Base.connection
      conn.execute(<<~SQL.squish)
        CREATE FUNCTION #{conn.quote_table_name(tenant)}.rbac_test_fn()
        RETURNS integer LANGUAGE sql AS 'SELECT 42'
      SQL
      RbacHelper.restore_default_connection!

      # app_user can call it (via ALTER DEFAULT PRIVILEGES ... ON FUNCTIONS)
      RbacHelper.connect_as(:app_user)
      result = ActiveRecord::Base.connection.execute(
        "SELECT #{ActiveRecord::Base.connection.quote_table_name(tenant)}.rbac_test_fn() AS val"
      )
      expect(result.first['val'].to_i).to(eq(42))
    ensure
      RbacHelper.restore_default_connection!
    end
  end

  context 'as db_manager' do
    before { RbacHelper.connect_as(:db_manager) }
    after  { RbacHelper.restore_default_connection! }

    it 'can CREATE TABLE and DROP SCHEMA' do
      conn = ActiveRecord::Base.connection
      conn.execute(
        "CREATE TABLE #{conn.quote_table_name(tenant)}.temp_table (id serial PRIMARY KEY)"
      )
      conn.execute("DROP TABLE #{conn.quote_table_name(tenant)}.temp_table")
      # Verify full DDL: db_manager can drop the schema it owns
      conn.execute("DROP SCHEMA #{conn.quote_table_name(tenant)} CASCADE")
      # Recreate for cleanup consistency
      conn.execute("CREATE SCHEMA #{conn.quote_table_name(tenant)}")
    end
  end
end
