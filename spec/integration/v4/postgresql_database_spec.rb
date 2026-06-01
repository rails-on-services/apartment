# frozen_string_literal: true

require 'spec_helper'
require 'rack'
require 'rack/mock'
require_relative 'support'

RSpec.describe('v4 PostgreSQL database-per-tenant integration', :integration,
               skip: (V4_INTEGRATION_AVAILABLE && V4IntegrationHelper.postgresql? ? false : 'requires PostgreSQL')) do
  include V4IntegrationHelper

  # Force-drop a PG database by terminating active connections first.
  # Safe to call even if the database does not exist.
  def force_drop_database(db_name)
    conn = ActiveRecord::Base.connection
    conn.execute(<<~SQL.squish)
      SELECT pg_terminate_backend(pid)
      FROM pg_stat_activity
      WHERE datname = '#{db_name}' AND pid <> pg_backend_pid()
    SQL
    conn.execute("DROP DATABASE IF EXISTS #{conn.quote_table_name(db_name)}")
  rescue StandardError => e
    warn "force_drop_database(#{db_name}): #{e.message}"
  end

  # All database names this spec may create (including environmentified variants).
  # rubocop:disable Lint/ConstantDefinitionInBlock
  ALL_TEST_DBS = %w[
    apt_db_tenant apt_db_drop_test apt_db_dup
    apt_db_iso_a apt_db_iso_b
    test_apt_env_tenant
    apt_db_fs_live apt_db_fs_gone apt_db_fs_req
  ].freeze
  # rubocop:enable Lint/ConstantDefinitionInBlock

  let(:created_tenants) { [] }

  before do
    V4IntegrationHelper.ensure_test_database!
    @config = V4IntegrationHelper.establish_default_connection!

    # Pre-clean any leftover databases from prior runs
    ALL_TEST_DBS.each { |db| force_drop_database(db) }

    Apartment.configure do |c|
      c.tenant_strategy = :database_name
      c.tenants_provider = -> { [] }
      c.default_tenant = @config['database'] # e.g. 'apartment_v4_test'
      c.check_pending_migrations = false
    end

    require 'apartment/adapters/postgresql_database_adapter'
    Apartment.adapter = Apartment::Adapters::PostgresqlDatabaseAdapter.new(
      @config.transform_keys(&:to_sym)
    )
    Apartment.activate!
  end

  after do
    # Disconnect all pools so DROP DATABASE succeeds
    ActiveRecord::Base.connection_handler.clear_all_connections!
    ActiveRecord::Base.establish_connection(@config)

    ALL_TEST_DBS.each { |db| force_drop_database(db) }

    Apartment.clear_config
    Apartment::Current.reset
  end

  describe 'database creation' do
    it 'creates a tenant database visible in pg_database' do
      Apartment.adapter.create('apt_db_tenant')
      created_tenants << 'apt_db_tenant'

      exists = ActiveRecord::Base.connection.select_value(
        "SELECT 1 FROM pg_database WHERE datname = 'apt_db_tenant'"
      )
      expect(exists).to(eq(1))
    end
  end

  describe 'database drop' do
    it 'removes the tenant database from pg_database' do
      Apartment.adapter.create('apt_db_drop_test')

      exists_before = ActiveRecord::Base.connection.select_value(
        "SELECT 1 FROM pg_database WHERE datname = 'apt_db_drop_test'"
      )
      expect(exists_before).to(eq(1))

      Apartment.adapter.drop('apt_db_drop_test')

      exists_after = ActiveRecord::Base.connection.select_value(
        "SELECT 1 FROM pg_database WHERE datname = 'apt_db_drop_test'"
      )
      expect(exists_after).to(be_nil)
    end
  end

  describe 'double create raises TenantExists' do
    it 'raises Apartment::TenantExists on duplicate create' do
      Apartment.adapter.create('apt_db_dup')
      created_tenants << 'apt_db_dup'

      expect do
        Apartment.adapter.create('apt_db_dup')
      end.to(raise_error(Apartment::TenantExists))
    end
  end

  describe 'data isolation across databases' do
    before do
      %w[apt_db_iso_a apt_db_iso_b].each do |tenant|
        Apartment.adapter.create(tenant)
        created_tenants << tenant

        Apartment::Tenant.switch(tenant) do
          V4IntegrationHelper.create_test_table!('widgets')
        end
      end
    end

    it 'isolates records between tenant databases' do
      Apartment::Tenant.switch('apt_db_iso_a') do
        ActiveRecord::Base.connection.execute("INSERT INTO widgets (name) VALUES ('from_a')")
      end

      Apartment::Tenant.switch('apt_db_iso_b') do
        count = ActiveRecord::Base.connection.select_value('SELECT COUNT(*) FROM widgets')
        expect(count.to_i).to(eq(0))
      end

      Apartment::Tenant.switch('apt_db_iso_a') do
        count = ActiveRecord::Base.connection.select_value('SELECT COUNT(*) FROM widgets')
        expect(count.to_i).to(eq(1))
      end
    end
  end

  describe 'resolve_connection_config' do
    it 'returns config with the correct database value' do
      resolved = Apartment.adapter.resolve_connection_config('acme')
      expect(resolved).to(be_a(Hash))
      expect(resolved['database']).to(eq('acme'))
    end
  end

  describe 'environmentified database names' do
    it 'creates a database prefixed with Rails environment' do
      Apartment.clear_config
      Apartment.configure do |c|
        c.tenant_strategy = :database_name
        c.tenants_provider = -> { [] }
        c.default_tenant = @config['database']
        c.environmentify_strategy = :prepend
        c.check_pending_migrations = false
      end

      Apartment.adapter = Apartment::Adapters::PostgresqlDatabaseAdapter.new(
        @config.transform_keys(&:to_sym)
      )
      Apartment.activate!

      Apartment.adapter.create('apt_env_tenant')
      created_tenants << 'apt_env_tenant'

      exists = ActiveRecord::Base.connection.select_value(
        "SELECT 1 FROM pg_database WHERE datname = 'test_apt_env_tenant'"
      )
      expect(exists).to(eq(1))
    end

    it 'returns environmentified database in resolve_connection_config' do
      Apartment.clear_config
      Apartment.configure do |c|
        c.tenant_strategy = :database_name
        c.tenants_provider = -> { [] }
        c.default_tenant = @config['database']
        c.environmentify_strategy = :prepend
        c.check_pending_migrations = false
      end

      Apartment.adapter = Apartment::Adapters::PostgresqlDatabaseAdapter.new(
        @config.transform_keys(&:to_sym)
      )

      resolved = Apartment.adapter.resolve_connection_config('acme')
      expect(resolved['database']).to(eq('test_acme'))
    end
  end

  # Issue #414: a database-per-tenant drop is unambiguous — connecting to the
  # gone database raises ActiveRecord::NoDatabaseError (PG SQLSTATE 3D000), so
  # the fail-safe turns the stale-positive 500 into a 404.
  describe 'missing-tenant fail-safe (database-per-tenant)' do
    it 'distinguishes a dropped database (gone) from a live one' do
      Apartment.adapter.create('apt_db_fs_live')
      Apartment.adapter.create('apt_db_fs_gone')
      created_tenants.push('apt_db_fs_live', 'apt_db_fs_gone')
      force_drop_database('apt_db_fs_gone') # out-of-band drop

      err = ActiveRecord::NoDatabaseError.new('database does not exist')
      adapter = Apartment.adapter
      expect(adapter.tenant_container_gone?(err, 'apt_db_fs_gone')).to(be(true))
      expect(adapter.tenant_container_gone?(err, 'apt_db_fs_live')).to(be(false))
    end

    it 'does not classify a non-NoDatabaseError (missing table in a live db stays 500)' do
      Apartment.adapter.create('apt_db_fs_live')
      created_tenants << 'apt_db_fs_live'
      err = ActiveRecord::StatementInvalid.new('relation "x" does not exist')
      expect(Apartment.adapter.tenant_container_gone?(err, 'apt_db_fs_live')).to(be(false))
    end

    it 'returns 404 (TenantNotFound) when the elevator switches to a dropped database' do
      Apartment.clear_config
      Apartment.configure do |c|
        c.tenant_strategy = :database_name
        c.tenants_provider = -> { ['apt_db_fs_req'] } # validator sees it as valid (stale positive)
        c.default_tenant = @config['database']
        c.check_pending_migrations = false
      end
      Apartment.adapter = Apartment::Adapters::PostgresqlDatabaseAdapter.new(@config.transform_keys(&:to_sym))
      Apartment.activate!

      Apartment.adapter.create('apt_db_fs_req')
      created_tenants << 'apt_db_fs_req'
      force_drop_database('apt_db_fs_req') # out-of-band drop

      app = ->(_env) { [200, {}, [ActiveRecord::Base.connection.select_value('SELECT 1').to_s]] }
      elevator = Apartment::Elevators::Generic.new(app, ->(_req) { 'apt_db_fs_req' })

      expect { elevator.call(Rack::MockRequest.env_for('http://example.com/')) }
        .to(raise_error(Apartment::TenantNotFound, /apt_db_fs_req/))
      expect(Apartment.tenant_validator.call('apt_db_fs_req')).to(be(false))
    end
  end
end
