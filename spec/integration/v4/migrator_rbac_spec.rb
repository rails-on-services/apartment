# frozen_string_literal: true

require 'spec_helper'
require_relative 'support'
require_relative 'support/rbac_helper'
require 'apartment/migrator'

RSpec.describe 'Migrator with migration_role', :integration, :rbac, :postgresql_only,
               skip: (!V4_INTEGRATION_AVAILABLE || V4IntegrationHelper.database_engine != 'postgresql') && 'requires PostgreSQL' do
  include V4IntegrationHelper

  let(:tenants) { %w[rbac_mig_one rbac_mig_two] }
  let(:migration_dir) { Dir.mktmpdir('apartment_rbac_migrations') }

  before do
    config = V4IntegrationHelper.establish_default_connection!
    RbacHelper.setup_connects_to!(config)

    Apartment.configure do |c|
      c.tenant_strategy = :schema
      c.tenants_provider = -> { tenants }
      c.default_tenant = 'public'
      c.migration_role = :db_manager
      c.app_role = RbacHelper::ROLES[:app_user]
      c.check_pending_migrations = false
    end

    Apartment.adapter = V4IntegrationHelper.build_adapter(config)
    Apartment.activate!

    # Create tenants as db_manager (so db_manager owns the schemas)
    ActiveRecord::Base.connected_to(role: :db_manager) do
      tenants.each { |t| Apartment.adapter.create(t) }
    end

    # Write a real migration file
    timestamp = '20260401000001'
    File.write(File.join(migration_dir, "#{timestamp}_create_rbac_test_widgets.rb"), <<~RUBY)
      class CreateRbacTestWidgets < ActiveRecord::Migration[7.2]
        def change
          create_table :rbac_test_widgets do |t|
            t.string :name
          end
        end
      end
    RUBY

    # Point AR's migration context at our temp directory.
    # ActiveRecord::Migrator.migrations_paths is what connection_pool.migration_context reads.
    @original_migrations_paths = ActiveRecord::Migrator.migrations_paths
    ActiveRecord::Migrator.migrations_paths = [migration_dir]
  end

  after do
    # Restore migration paths
    ActiveRecord::Migrator.migrations_paths = @original_migrations_paths

    V4IntegrationHelper.establish_default_connection!
    Apartment.adapter = V4IntegrationHelper.build_adapter(
      V4IntegrationHelper.default_connection_config
    )
    V4IntegrationHelper.cleanup_tenants!(tenants, Apartment.adapter)
    Apartment.clear_config
    Apartment::Current.reset
    RbacHelper.teardown_rbac_connections!
    FileUtils.rm_rf(migration_dir)
  end

  it 'runs migrations as db_manager (table owned by db_manager)' do
    migrator = Apartment::Migrator.new(threads: 0)
    result = migrator.run

    expect(result).to be_success

    tenants.each do |t|
      Apartment::Tenant.switch(t) do
        owner = ActiveRecord::Base.connection.execute(<<~SQL).first['tableowner']
          SELECT tableowner FROM pg_tables
          WHERE schemaname = '#{t}' AND tablename = 'rbac_test_widgets'
        SQL
        expect(owner).to eq(RbacHelper::ROLES[:db_manager])
      end
    end
  end

  it 'app_user can DML on migrated tables via default privileges' do
    Apartment::Migrator.new(threads: 0).run

    RbacHelper.connect_as(:app_user)
    conn = ActiveRecord::Base.connection

    tenants.each do |t|
      conn.execute("INSERT INTO #{conn.quote_table_name(t)}.rbac_test_widgets (name) VALUES ('test')")
      result = conn.execute("SELECT name FROM #{conn.quote_table_name(t)}.rbac_test_widgets")
      expect(result.first['name']).to eq('test')
    end

    RbacHelper.restore_default_connection!
  end

  it 'evicts migration-role pools after run' do
    Apartment::Migrator.new(threads: 0).run

    db_mgr_keys = Apartment.pool_manager.stats[:tenants].select { |k| k.end_with?(':db_manager') }
    expect(db_mgr_keys).to be_empty
  end

  context 'with parallel threads' do
    it 'each thread uses db_manager credentials' do
      migrator = Apartment::Migrator.new(threads: 2)
      result = migrator.run

      expect(result).to be_success

      tenants.each do |t|
        Apartment::Tenant.switch(t) do
          owner = ActiveRecord::Base.connection.execute(<<~SQL).first['tableowner']
            SELECT tableowner FROM pg_tables
            WHERE schemaname = '#{t}' AND tablename = 'rbac_test_widgets'
          SQL
          expect(owner).to eq(RbacHelper::ROLES[:db_manager])
        end
      end
    end
  end
end
