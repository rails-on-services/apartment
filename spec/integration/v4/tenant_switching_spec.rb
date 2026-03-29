# frozen_string_literal: true

require 'spec_helper'
require_relative 'support'

RSpec.describe('v4 Tenant switching integration', :integration,
               skip: (V4_INTEGRATION_AVAILABLE ? false : 'requires ActiveRecord + sqlite3')) do
  let(:tmp_dir) { Dir.mktmpdir('apartment_integration') }
  # The adapter derives the tenant directory from File.dirname of the base config's database path.
  # All tenant files land in the same directory: <tmp_dir>/<tenant>.sqlite3
  let(:default_db) { File.join(tmp_dir, 'default.sqlite3') }

  before do
    ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: default_db)
    ActiveRecord::Base.connection.create_table(:widgets, force: true) do |t|
      t.string(:name)
    end

    stub_const('Widget', Class.new(ActiveRecord::Base) do
      self.table_name = 'widgets'
    end)

    Apartment.configure do |config|
      config.tenant_strategy = :database_name
      config.tenants_provider = -> { %w[tenant_a tenant_b] }
      config.default_tenant = 'default'
    end

    # The adapter uses base_config['database'] to derive the directory for tenant files.
    # With default.sqlite3 in tmp_dir, tenant files will be <tmp_dir>/tenant_a.sqlite3, etc.
    Apartment.adapter = Apartment::Adapters::SQLite3Adapter.new(
      ActiveRecord::Base.connection_db_config.configuration_hash
    )

    Apartment.activate!

    # Create tenants — SQLite3Adapter#create just ensures the directory exists;
    # the actual .sqlite3 file is created on first connection.
    %w[tenant_a tenant_b].each do |tenant|
      Apartment.adapter.create(tenant)
      # Create the widgets table inside each tenant database.
      Apartment::Tenant.switch(tenant) do
        ActiveRecord::Base.connection.create_table(:widgets, force: true) do |t|
          t.string(:name)
        end
      end
    end
  end

  after do
    Apartment.clear_config
    Apartment::Current.reset
    ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
    FileUtils.rm_rf(tmp_dir)
  end

  it 'isolates data between tenants' do
    Apartment::Tenant.switch('tenant_a') do
      Widget.create!(name: 'Alice Widget')
    end

    Apartment::Tenant.switch('tenant_b') do
      expect(Widget.count).to(eq(0))
    end

    Apartment::Tenant.switch('tenant_a') do
      expect(Widget.count).to(eq(1))
      expect(Widget.first.name).to(eq('Alice Widget'))
    end
  end

  it 'restores tenant context on exception' do
    expect do
      Apartment::Tenant.switch('tenant_a') do
        raise('boom')
      end
    end.to(raise_error('boom'))

    expect(Apartment::Tenant.current).to(eq('default'))
  end

  it 'supports nested switching' do
    Apartment::Tenant.switch('tenant_a') do
      Widget.create!(name: 'A')
      Apartment::Tenant.switch('tenant_b') do
        expect(Apartment::Tenant.current).to(eq('tenant_b'))
        Widget.create!(name: 'B')
      end
      expect(Apartment::Tenant.current).to(eq('tenant_a'))
      expect(Widget.count).to(eq(1))
    end

    # Verify tenant_b got its own record
    Apartment::Tenant.switch('tenant_b') do
      expect(Widget.count).to(eq(1))
      expect(Widget.first.name).to(eq('B'))
    end
  end
end
