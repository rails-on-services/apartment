# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../lib/apartment/adapters/mysql2_adapter'
require_relative '../../../lib/apartment/adapters/trilogy_adapter'

# Minimal ActiveRecord stubs for SQL execution tests.
unless defined?(ActiveRecord::Base)
  module ActiveRecord
    class Base
      def self.connection
        raise('stub: override with allow in tests')
      end
    end
  end
end

# Minimal Rails stub for environmentify tests.
unless defined?(Rails)
  module Rails
    def self.env
      'test'
    end
  end
end

# Shared examples for MySQL-family adapters (MySQL2 and Trilogy share identical behavior).
RSpec.shared_examples('a MySQL adapter') do
  let(:connection_config) { { adapter: adapter_name, host: 'localhost', database: 'myapp' } }
  let(:adapter) { described_class.new(connection_config) }

  before do
    Apartment.configure do |c|
      c.tenant_strategy = :database_name
      c.tenants_provider = -> { %w[t1 t2] }
      c.default_tenant = 'myapp'
      c.schema_load_strategy = nil
    end
  end

  # Helper: reconfigure Apartment with overrides (Config is frozen after configure,
  # so we must reconfigure rather than stub individual accessors).
  def reconfigure(**overrides)
    Apartment.configure do |c|
      c.tenant_strategy = :database_name
      c.tenants_provider = -> { %w[t1 t2] }
      c.default_tenant = 'myapp'
      c.schema_load_strategy = nil
      overrides.each { |key, val| c.send(:"#{key}=", val) }
    end
  end

  describe '#resolve_connection_config' do
    it 'returns config with database key set to tenant name (nil strategy = plain name)' do
      result = adapter.resolve_connection_config('acme')

      expect(result['database']).to(eq('acme'))
    end

    it 'stringifies all config keys' do
      result = adapter.resolve_connection_config('acme')

      expect(result.keys).to(all(be_a(String)))
      expect(result['adapter']).to(eq(adapter_name))
      expect(result['host']).to(eq('localhost'))
    end

    it 'uses environmentify with :prepend strategy' do
      reconfigure(environmentify_strategy: :prepend)
      allow(Rails).to(receive(:env).and_return('staging'))

      result = adapter.resolve_connection_config('acme')

      expect(result['database']).to(eq('staging_acme'))
    end

    it 'uses environmentify with :append strategy' do
      reconfigure(environmentify_strategy: :append)
      allow(Rails).to(receive(:env).and_return('staging'))

      result = adapter.resolve_connection_config('acme')

      expect(result['database']).to(eq('acme_staging'))
    end

    it 'preserves all original connection config keys' do
      config = { adapter: adapter_name, host: 'db.example.com', database: 'app', port: 3306, pool: 10 }
      local_adapter = described_class.new(config)

      result = local_adapter.resolve_connection_config('tenant1')

      expect(result['port']).to(eq(3306))
      expect(result['pool']).to(eq(10))
      expect(result['host']).to(eq('db.example.com'))
    end

    it 'does not mutate the original connection_config' do
      adapter.resolve_connection_config('acme')

      expect(adapter.connection_config).to(eq(connection_config))
      expect(adapter.connection_config[:database]).to(eq('myapp'))
    end
  end

  describe '#shared_pinned_connection?' do
    it 'returns true (MySQL supports cross-database queries on same server)' do
      expect(adapter.shared_pinned_connection?).to(be(true))
    end

    it 'returns false when force_separate_pinned_pool is true' do
      reconfigure(force_separate_pinned_pool: true)
      expect(adapter.shared_pinned_connection?).to(be(false))
    end
  end

  describe '#qualify_pinned_table_name' do
    it 'qualifies convention-named model with database name from base_config' do
      klass = Class.new(ActiveRecord::Base) { include Apartment::Model }
      stub_const('MysqlPinned', klass)

      expect(klass).to(receive(:table_name_prefix=).with('myapp.'))
      expect(klass).to(receive(:reset_table_name))

      adapter.qualify_pinned_table_name(klass)
    end

    it 'qualifies explicit table_name with database name from base_config' do
      klass = Class.new(ActiveRecord::Base) { include Apartment::Model }
      stub_const('MysqlExplicit', klass)
      klass.instance_variable_set(:@table_name, 'custom_jobs')
      allow(klass).to(receive_messages(compute_table_name: 'mysql_explicits', table_name: 'custom_jobs'))

      expect(klass).to(receive(:table_name=).with('myapp.custom_jobs'))

      adapter.qualify_pinned_table_name(klass)
    end

    it 'strips existing database prefix before re-qualifying' do
      klass = Class.new(ActiveRecord::Base) { include Apartment::Model }
      stub_const('MysqlRequalify', klass)
      klass.instance_variable_set(:@table_name, 'old_db.jobs')
      allow(klass).to(receive_messages(compute_table_name: 'mysql_requalifies', table_name: 'old_db.jobs'))

      expect(klass).to(receive(:table_name=).with('myapp.jobs'))

      adapter.qualify_pinned_table_name(klass)
    end
  end

  describe '#create (via create_tenant)' do
    let(:connection) { double('Connection') }

    before do
      allow(ActiveRecord::Base).to(receive(:connection).and_return(connection))
      allow(Apartment::Instrumentation).to(receive(:instrument))
    end

    it 'executes CREATE DATABASE with quoted environmentified name' do
      allow(connection).to(receive(:quote_table_name).with('acme').and_return('`acme`'))
      expect(connection).to(receive(:execute).with('CREATE DATABASE IF NOT EXISTS `acme`'))

      adapter.create('acme')
    end

    it 'quotes tenant names that need escaping' do
      allow(connection).to(receive(:quote_table_name).with('my-tenant').and_return('`my-tenant`'))
      expect(connection).to(receive(:execute).with('CREATE DATABASE IF NOT EXISTS `my-tenant`'))

      adapter.create('my-tenant')
    end

    it 'uses environmentified name for CREATE DATABASE' do
      reconfigure(environmentify_strategy: :prepend)
      allow(Rails).to(receive(:env).and_return('test'))
      allow(connection).to(receive(:quote_table_name).with('test_acme').and_return('`test_acme`'))
      expect(connection).to(receive(:execute).with('CREATE DATABASE IF NOT EXISTS `test_acme`'))

      adapter.create('acme')
    end

    it 'validates the environmentified name against MySQL length limit' do
      # Raw name is 60 chars (valid for MySQL 64 limit), but "test_" prefix makes 65 (exceeds 64)
      reconfigure(environmentify_strategy: :prepend)
      allow(Rails).to(receive(:env).and_return('test'))

      tenant = 'a' * 60
      expect { adapter.create(tenant) }
        .to(raise_error(Apartment::ConfigurationError, /too long.*65.*max 64/))
    end
  end

  describe '#grant_privileges (private)' do
    let(:connection) { double('Connection') }

    before do
      allow(connection).to(receive(:quote).with('app_user').and_return("'app_user'"))
      allow(connection).to(receive(:quote_table_name)) { |name| "`#{name}`" }
    end

    it 'executes exactly 1 SQL statement' do
      expect(connection).to(receive(:execute).once)

      adapter.send(:grant_privileges, 'acme', connection, 'app_user')
    end

    it 'quotes the database name using quote_table_name' do
      expect(connection).to(receive(:quote_table_name).with('acme').and_return('`acme`'))
      allow(connection).to(receive(:execute))

      adapter.send(:grant_privileges, 'acme', connection, 'app_user')
    end

    it 'environmentifies the database name in the GRANT' do
      reconfigure(environmentify_strategy: :prepend)
      allow(Rails).to(receive(:env).and_return('staging'))
      allow(connection).to(receive(:quote_table_name).with('staging_acme').and_return('`staging_acme`'))

      expect(connection).to(receive(:execute)
        .with("GRANT SELECT, INSERT, UPDATE, DELETE ON `staging_acme`.* TO 'app_user'@'%'"))

      adapter.send(:grant_privileges, 'acme', connection, 'app_user')
    end
  end

  describe '#drop (via drop_tenant)' do
    let(:connection) { double('Connection') }
    let(:pool_manager) { Apartment.pool_manager }

    before do
      allow(ActiveRecord::Base).to(receive(:connection).and_return(connection))
      allow(Apartment::Instrumentation).to(receive(:instrument))
      allow(pool_manager).to(receive(:remove_tenant).and_return([]))
      allow(Apartment).to(receive(:deregister_shard))
    end

    it 'executes DROP DATABASE IF EXISTS with quoted environmentified name' do
      allow(connection).to(receive(:quote_table_name).with('acme').and_return('`acme`'))
      expect(connection).to(receive(:execute).with('DROP DATABASE IF EXISTS `acme`'))

      adapter.drop('acme')
    end

    it 'quotes tenant names that need escaping' do
      allow(connection).to(receive(:quote_table_name).with('my-tenant').and_return('`my-tenant`'))
      expect(connection).to(receive(:execute).with('DROP DATABASE IF EXISTS `my-tenant`'))

      adapter.drop('my-tenant')
    end

    it 'uses environmentified name for DROP DATABASE' do
      reconfigure(environmentify_strategy: :prepend)
      allow(Rails).to(receive(:env).and_return('test'))
      allow(connection).to(receive(:quote_table_name).with('test_acme').and_return('`test_acme`'))
      expect(connection).to(receive(:execute).with('DROP DATABASE IF EXISTS `test_acme`'))

      adapter.drop('acme')
    end
  end
end

RSpec.describe(Apartment::Adapters::Mysql2Adapter) do
  describe 'inheritance' do
    it 'is a subclass of AbstractAdapter' do
      expect(described_class).to(be < Apartment::Adapters::AbstractAdapter)
    end
  end

  it_behaves_like 'a MySQL adapter' do
    let(:adapter_name) { 'mysql2' }
  end
end

RSpec.describe(Apartment::Adapters::TrilogyAdapter) do
  describe 'inheritance' do
    it 'is a subclass of Mysql2Adapter' do
      expect(described_class).to(be < Apartment::Adapters::Mysql2Adapter)
    end

    it 'is a subclass of AbstractAdapter' do
      expect(described_class).to(be < Apartment::Adapters::AbstractAdapter)
    end
  end

  it_behaves_like 'a MySQL adapter' do
    let(:adapter_name) { 'trilogy' }
  end
end
