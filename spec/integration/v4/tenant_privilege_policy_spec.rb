# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require_relative 'support'
require_relative 'support/rbac_helper'

# The two properties the two-phase policy design turns on, against real roles.
#
# Both are stated in docs/designs/v4-rbac-contract.md and neither is observable from
# the statements alone: one is about WHERE in the create sequence a policy runs, the
# other about WHICH role a recorded rule belongs to.
RSpec.describe('Two-phase tenant_privilege_policy', :integration, :postgresql_only, :rbac,
               skip: (V4_INTEGRATION_AVAILABLE && V4IntegrationHelper.postgresql? ? false : 'requires PG')) do
  include V4IntegrationHelper

  let(:app_role) { RbacHelper::ROLES[:app_user] }
  let(:ddl_user) { RbacHelper::ROLES[:db_manager] }

  # Apartment configured for schema-per-tenant on ddl_role, with whatever policy the
  # context under test needs. Deliberately not wrapped in connected_to: the gem is
  # responsible for putting tenant DDL on ddl_role.
  def configure_apartment!(tenant, policy, schema_file: nil)
    config = V4IntegrationHelper.establish_default_connection!
    RbacHelper.setup_connects_to!(config)

    Apartment.configure do |c|
      c.tenant_strategy = :schema
      c.tenants_provider = -> { [tenant] }
      c.default_tenant = 'public'
      c.ddl_role = :db_manager
      c.tenant_privilege_policy = policy
      c.schema_load_strategy = schema_file ? :schema_rb : nil
      c.schema_file = schema_file
      c.check_pending_migrations = false
    end

    Apartment.adapter = V4IntegrationHelper.build_adapter(config)
    Apartment.activate!
  end

  def restore_and_cleanup!(tenant)
    RbacHelper.teardown_rbac_connections!

    V4IntegrationHelper.establish_default_connection!
    Apartment.adapter = V4IntegrationHelper.build_adapter(
      V4IntegrationHelper.default_connection_config
    )
    V4IntegrationHelper.cleanup_tenants!([tenant], Apartment.adapter)
    Apartment.clear_config
    Apartment::Current.reset
  end

  # The regression a single post-import call site would have introduced. This policy
  # grants nothing on existing objects — no GRANT ON ALL TABLES — so the imported table
  # is reachable only because the default-privileges rules were recorded BEFORE the
  # import. Move the same policy after the import and every imported table is
  # ungranted, with nothing raised until an ordinary query touches it.
  context 'with a default-privileges-only policy' do
    let(:tenant) { 'rbac_policy_import_tenant' }

    before do
      @tmp_dir = Dir.mktmpdir('apartment_policy_schema')
      File.write(File.join(@tmp_dir, 'schema.rb'), <<~SCHEMA)
        ActiveRecord::Schema.define(version: 1) do
          create_table(:imported_widgets, force: true) do |t|
            t.string(:name)
          end
        end
      SCHEMA

      policy = lambda { |ctx|
        next unless ctx.before_schema_load?

        conn = ctx.connection
        grantee = conn.quote_column_name(RbacHelper::ROLES[:app_user])
        grantor = conn.quote_column_name(ctx.db_role)
        defaults = "ALTER DEFAULT PRIVILEGES FOR ROLE #{grantor} IN SCHEMA #{ctx.quoted_container} GRANT"

        conn.execute("GRANT USAGE ON SCHEMA #{ctx.quoted_container} TO #{grantee}")
        conn.execute("#{defaults} SELECT, INSERT, UPDATE, DELETE ON TABLES TO #{grantee}")
        conn.execute("#{defaults} USAGE, SELECT ON SEQUENCES TO #{grantee}")
        conn.execute("#{defaults} EXECUTE ON FUNCTIONS TO #{grantee}")
      }

      configure_apartment!(tenant, policy, schema_file: File.join(@tmp_dir, 'schema.rb'))
      Apartment.adapter.create(tenant)
    end

    after do
      restore_and_cleanup!(tenant)
      FileUtils.remove_entry(@tmp_dir) if @tmp_dir && File.directory?(@tmp_dir)
    end

    it 'covers schema-imported tables, because its rules were recorded before the import' do
      RbacHelper.connect_as(:app_user)
      conn = ActiveRecord::Base.connection
      table = "#{conn.quote_table_name(tenant)}.imported_widgets"
      conn.execute("INSERT INTO #{table} (name) VALUES ('imported')")

      expect(conn.select_value("SELECT name FROM #{table}")).to(eq('imported'))
    ensure
      RbacHelper.restore_default_connection!
    end
  end

  # FOR ROLE names the grantor rather than letting PostgreSQL infer it from whoever
  # executed the statement, so the rule is correct by statement rather than by
  # position. The only way to observe the difference is to execute the statements as
  # one role while naming another, which is why this drives the adapter seam directly
  # instead of going through create: create always runs on ddl_role, so there the
  # implied grantor and the named one coincide and the token cannot be seen working.
  context 'with an explicit FOR ROLE grantor' do
    let(:tenant) { 'rbac_policy_for_role_tenant' }

    before do
      # No policy: the only privilege state in this schema is what the example issues.
      configure_apartment!(tenant, nil)
      Apartment.adapter.create(tenant)
    end

    after { restore_and_cleanup!(tenant) }

    it 'records the rule against the role it names, not the role that executed it' do
      # Executed on the default (superuser) connection, naming db_manager as grantor.
      ctx = Apartment::Privileges::Context.new(
        tenant: tenant, container_name: tenant,
        connection: ActiveRecord::Base.connection,
        db_role: ddl_user, phase: :before_schema_load
      )
      statements = Apartment.adapter.standard_privilege_statements(ctx, grant_to: app_role)
      statements.each { |sql| ActiveRecord::Base.connection.execute(sql) }

      # db_manager — the named grantor, not the executing role — then creates a table.
      ActiveRecord::Base.connected_to(role: :db_manager) do
        conn = ActiveRecord::Base.connection
        conn.execute(<<~SQL.squish)
          CREATE TABLE #{conn.quote_table_name(tenant)}.grantor_widgets (
            id serial PRIMARY KEY,
            name varchar(255)
          )
        SQL
      end

      RbacHelper.connect_as(:app_user)
      conn = ActiveRecord::Base.connection
      table = "#{conn.quote_table_name(tenant)}.grantor_widgets"
      conn.execute("INSERT INTO #{table} (name) VALUES ('named grantor')")

      expect(conn.select_value("SELECT name FROM #{table}")).to(eq('named grantor'))
    ensure
      RbacHelper.restore_default_connection!
    end
  end
end
