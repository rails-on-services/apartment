# frozen_string_literal: true

require 'spec_helper'
require_relative 'support'
require_relative '../../../lib/apartment/cli'

RSpec.describe('v4 CLI integration', :integration,
               skip: (V4_INTEGRATION_AVAILABLE ? false : 'requires ActiveRecord + database gem')) do
  include V4IntegrationHelper

  let(:tmp_dir) { Dir.mktmpdir('apartment_cli') }
  let(:tenants) { %w[cli_alpha cli_beta cli_gamma] }

  before do
    V4IntegrationHelper.ensure_test_database! unless V4IntegrationHelper.sqlite?
    config = V4IntegrationHelper.establish_default_connection!(tmp_dir: tmp_dir)
    V4IntegrationHelper.create_test_table!

    Apartment.configure do |c|
      c.tenant_strategy = V4IntegrationHelper.tenant_strategy
      c.tenants_provider = -> { tenants }
      c.default_tenant = V4IntegrationHelper.default_tenant
      c.check_pending_migrations = false
    end

    Apartment.adapter = V4IntegrationHelper.build_adapter(config)
    Apartment.activate!
  end

  after do
    V4IntegrationHelper.cleanup_tenants!(tenants, Apartment.adapter)
    Apartment.clear_config
    Apartment::Current.reset
    ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:') if V4IntegrationHelper.sqlite?
    FileUtils.rm_rf(tmp_dir)
  end

  describe 'tenants list' do
    it 'lists all tenants from tenants_provider' do
      output = capture_stdout { Apartment::CLI::Tenants.new.invoke(:list) }

      tenants.each do |t|
        expect(output).to(include(t), "Expected '#{t}' in list output")
      end
    end
  end

  describe 'tenants create' do
    it 'creates a tenant accessible via switch' do
      capture_stdout { Apartment::CLI::Tenants.new.invoke(:create, ['cli_alpha']) }

      Apartment::Tenant.switch('cli_alpha') do
        V4IntegrationHelper.create_test_table!('widgets', connection: ActiveRecord::Base.connection)
        ActiveRecord::Base.connection.execute('SELECT 1')
      end
    end
  end

  describe 'tenants drop' do
    it 'drops a tenant so it no longer exists' do
      Apartment.adapter.create('cli_alpha')

      # Switch once to ensure the pool is tracked
      Apartment::Tenant.switch('cli_alpha') do
        ActiveRecord::Base.connection.execute('SELECT 1')
      end

      role = ActiveRecord::Base.current_role
      expect(Apartment.pool_manager.tracked?("cli_alpha:#{role}")).to(be(true))

      begin
        ENV['APARTMENT_FORCE'] = '1'
        capture_stdout { Apartment::CLI::Tenants.new.invoke(:drop, ['cli_alpha']) }
      ensure
        ENV.delete('APARTMENT_FORCE')
      end

      # After drop, the pool should be removed
      expect(Apartment.pool_manager.tracked?("cli_alpha:#{role}")).to(be(false))
    end
  end

  describe 'pool stats' do
    it 'displays pool count and tenant names' do
      Apartment.adapter.create('cli_alpha')
      Apartment::Tenant.switch('cli_alpha') do
        ActiveRecord::Base.connection.execute('SELECT 1')
      end

      output = capture_stdout { Apartment::CLI::Pool.new.invoke(:stats) }

      expect(output).to(include('Total pools:'))
      expect(output).to(include('cli_alpha'))
    end
  end

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end
end
