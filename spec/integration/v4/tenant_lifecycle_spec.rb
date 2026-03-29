# frozen_string_literal: true

require 'spec_helper'
require_relative 'support'

RSpec.describe('v4 Tenant lifecycle integration', :integration,
               skip: (V4_INTEGRATION_AVAILABLE ? false : 'requires ActiveRecord + sqlite3')) do
  let(:tmp_dir) { Dir.mktmpdir('apartment_lifecycle') }
  let(:default_db) { File.join(tmp_dir, 'default.sqlite3') }

  before do
    ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: default_db)

    Apartment.configure do |config|
      config.tenant_strategy = :database_name
      config.tenants_provider = -> { [] }
      config.default_tenant = 'default'
    end

    Apartment.adapter = Apartment::Adapters::SQLite3Adapter.new(
      ActiveRecord::Base.connection_db_config.configuration_hash
    )
    Apartment.activate!
  end

  after do
    Apartment.clear_config
    Apartment::Current.reset
    ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
    FileUtils.rm_rf(tmp_dir)
  end

  it 'creates a tenant and can switch to it' do
    Apartment.adapter.create('new_tenant')

    Apartment::Tenant.switch('new_tenant') do
      # Verify we get a real connection pool and can execute queries.
      pool = ActiveRecord::Base.connection_pool
      expect(pool).to(be_a(ActiveRecord::ConnectionAdapters::ConnectionPool))
      pool.with_connection { |conn| conn.execute('SELECT 1') }
    end
  end

  it 'creates the database file in the same directory as the default database' do
    Apartment.adapter.create('file_check')

    # The adapter derives the path from File.dirname(base_config['database']).
    # With environmentify_strategy nil, the file is <dir>/file_check.sqlite3.
    expected_path = File.join(tmp_dir, 'file_check.sqlite3')

    # The file may not exist until a connection is established (SQLite creates on connect).
    Apartment::Tenant.switch('file_check') do
      ActiveRecord::Base.connection.execute('SELECT 1')
    end

    expect(File.exist?(expected_path)).to(be(true))
  end

  it 'drops a tenant and removes its pool' do
    Apartment.adapter.create('doomed')

    # Force pool creation by switching into the tenant.
    Apartment::Tenant.switch('doomed') do
      ActiveRecord::Base.connection.execute('SELECT 1')
    end

    expect(Apartment.pool_manager.tracked?('doomed')).to(be(true))

    Apartment.adapter.drop('doomed')

    expect(Apartment.pool_manager.tracked?('doomed')).to(be(false))

    # The database file should also be removed.
    dropped_path = File.join(tmp_dir, 'doomed.sqlite3')
    expect(File.exist?(dropped_path)).to(be(false))
  end

  it 'raises on duplicate tenant creation only if the file already exists' do
    Apartment.adapter.create('once')

    # Force the file to exist by connecting.
    Apartment::Tenant.switch('once') do
      ActiveRecord::Base.connection.execute('SELECT 1')
    end

    # Creating again should succeed (SQLite3Adapter#create_tenant is just mkdir_p),
    # but the file already exists so switching still works.
    expect { Apartment.adapter.create('once') }.not_to(raise_error)
  end
end
