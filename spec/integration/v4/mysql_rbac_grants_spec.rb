# frozen_string_literal: true

require 'spec_helper'
require_relative 'support'
require_relative 'support/rbac_helper'

RSpec.describe 'MySQL RBAC privilege grants', :integration, :rbac, :mysql_only,
               skip: (!V4_INTEGRATION_AVAILABLE || V4IntegrationHelper.database_engine != 'mysql') && 'requires MySQL' do
  include V4IntegrationHelper

  let(:tenant) { 'rbac_grants_tenant' }

  before do
    config = V4IntegrationHelper.establish_default_connection!

    # Create tenant as db_manager with app_role grants
    RbacHelper.connect_as(:db_manager)

    Apartment.configure do |c|
      c.tenant_strategy = :database_name
      c.tenants_provider = -> { [tenant] }
      c.default_tenant = V4IntegrationHelper.default_tenant
      c.app_role = RbacHelper::ROLES[:app_user]
      c.check_pending_migrations = false
    end

    Apartment.adapter = V4IntegrationHelper.build_adapter(
      config.merge('username' => RbacHelper::ROLES[:db_manager])
    )
    Apartment.activate!
    Apartment.adapter.create(tenant)

    # Create a test table inside the tenant database
    Apartment::Tenant.switch(tenant) do
      ActiveRecord::Base.connection.execute(<<~SQL)
        CREATE TABLE widgets (
          id INT AUTO_INCREMENT PRIMARY KEY,
          name VARCHAR(255)
        )
      SQL
    end

    RbacHelper.restore_default_connection!
  end

  after do
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
    let(:db_name) { Apartment.adapter.environmentify(tenant) }

    before { RbacHelper.connect_as(:app_user) }
    after  { RbacHelper.restore_default_connection! }

    it 'can SELECT, INSERT, UPDATE, DELETE' do
      conn = ActiveRecord::Base.connection
      conn.execute("INSERT INTO `#{db_name}`.widgets (name) VALUES ('test')")

      result = conn.execute("SELECT name FROM `#{db_name}`.widgets")
      expect(result.first['name']).to eq('test')

      conn.execute("UPDATE `#{db_name}`.widgets SET name = 'updated'")
      conn.execute("DELETE FROM `#{db_name}`.widgets")
    end

    it 'cannot CREATE TABLE in the tenant database' do
      expect {
        ActiveRecord::Base.connection.execute(
          "CREATE TABLE `#{db_name}`.forbidden (id INT PRIMARY KEY)"
        )
      }.to raise_error(ActiveRecord::StatementInvalid, /command denied|Access denied/)
    end

    it 'cannot DROP DATABASE' do
      expect {
        ActiveRecord::Base.connection.execute("DROP DATABASE `#{db_name}`")
      }.to raise_error(ActiveRecord::StatementInvalid, /command denied|Access denied/)
    end
  end

  context 'as db_manager' do
    let(:db_name) { Apartment.adapter.environmentify(tenant) }

    before { RbacHelper.connect_as(:db_manager) }
    after  { RbacHelper.restore_default_connection! }

    it 'can CREATE TABLE and DROP it' do
      conn = ActiveRecord::Base.connection
      conn.execute("CREATE TABLE `#{db_name}`.temp_table (id INT PRIMARY KEY)")
      conn.execute("DROP TABLE `#{db_name}`.temp_table")
    end
  end
end
