# frozen_string_literal: true

require 'spec_helper'
require_relative 'support'
require_relative 'support/rbac_helper'

# Tenant creation is DDL, so it runs on config.migration_role like migrations do.
#
# The case that matters is an adopter who created a tenant from ordinary application
# code rather than from inside connected_to(role: :db_manager). The create-time grants
# end with ALTER DEFAULT PRIVILEGES, which PostgreSQL scopes to the role that EXECUTED
# it, so a rule recorded under the writing role does not cover the tables migrations
# later create under the migration role. Nothing raises at create time; the first
# ordinary query against a migration-created table gets `permission denied`.
#
# The sibling spec (migrator_rbac_spec.rb) creates its tenants inside an explicit
# connected_to(role: :db_manager) and so cannot see this: it encodes the discipline
# whose absence is the bug.
RSpec.describe('Tenant create under migration_role', :integration, :postgresql_only, :rbac,
               skip: (V4_INTEGRATION_AVAILABLE && V4IntegrationHelper.postgresql? ? false : 'requires PG')) do
  include V4IntegrationHelper

  let(:tenant) { 'rbac_create_role_tenant' }

  before do
    config = V4IntegrationHelper.establish_default_connection!
    RbacHelper.setup_connects_to!(config)

    Apartment.configure do |c|
      c.tenant_strategy = :schema
      c.tenants_provider = -> { [tenant] }
      c.default_tenant = 'public'
      c.migration_role = :db_manager
      c.app_role = RbacHelper::ROLES[:app_user]
      c.check_pending_migrations = false
    end

    Apartment.adapter = V4IntegrationHelper.build_adapter(config)
    Apartment.activate!

    # Deliberately NOT wrapped in connected_to(role: :db_manager). The gem is
    # responsible for putting tenant DDL on the migration role.
    Apartment.adapter.create(tenant)
  end

  after do
    RbacHelper.teardown_rbac_connections!

    V4IntegrationHelper.establish_default_connection!
    Apartment.adapter = V4IntegrationHelper.build_adapter(
      V4IntegrationHelper.default_connection_config
    )
    V4IntegrationHelper.cleanup_tenants!([tenant], Apartment.adapter)
    Apartment.clear_config
    Apartment::Current.reset
  end

  it 'creates the tenant container owned by the migration role' do
    conn = ActiveRecord::Base.connection
    owner = conn.select_value(
      "SELECT nspowner::regrole::text FROM pg_namespace WHERE nspname = #{conn.quote(tenant)}"
    )

    expect(owner).to(eq(RbacHelper::ROLES[:db_manager]))
  end

  it 'records default privileges under the migration role, so later DDL is covered' do
    # Stands in for a migration: a table added by the migration role after create.
    ActiveRecord::Base.connected_to(role: :db_manager) do
      conn = ActiveRecord::Base.connection
      conn.execute(<<~SQL.squish)
        CREATE TABLE #{conn.quote_table_name(tenant)}.late_widgets (
          id serial PRIMARY KEY,
          name varchar(255)
        )
      SQL
    end

    RbacHelper.connect_as(:app_user)
    conn = ActiveRecord::Base.connection
    conn.execute("INSERT INTO #{conn.quote_table_name(tenant)}.late_widgets (name) VALUES ('covered')")

    expect(conn.select_value("SELECT name FROM #{conn.quote_table_name(tenant)}.late_widgets"))
      .to(eq('covered'))
  ensure
    RbacHelper.restore_default_connection!
  end

  it 'leaves no migration-role pool registered for the new tenant' do
    expect(Apartment.pool_manager.stats[:tenants]).not_to(include("#{tenant}:db_manager"))
  end
end
