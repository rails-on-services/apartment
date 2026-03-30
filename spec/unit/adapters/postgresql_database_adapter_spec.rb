# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../lib/apartment/adapters/postgresql_database_adapter'

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

RSpec.describe(Apartment::Adapters::PostgresqlDatabaseAdapter) do
  let(:connection_config) { { adapter: 'postgresql', host: 'localhost', database: 'myapp' } }
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

  describe 'inheritance' do
    it 'is a subclass of AbstractAdapter' do
      expect(described_class).to(be < Apartment::Adapters::AbstractAdapter)
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
      expect(result['adapter']).to(eq('postgresql'))
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
      config = { adapter: 'postgresql', host: 'db.example.com', database: 'app', port: 5432, pool: 10 }
      local_adapter = described_class.new(config)

      result = local_adapter.resolve_connection_config('tenant1')

      expect(result['port']).to(eq(5432))
      expect(result['pool']).to(eq(10))
      expect(result['host']).to(eq('db.example.com'))
    end

    it 'does not mutate the original connection_config' do
      adapter.resolve_connection_config('acme')

      expect(adapter.connection_config).to(eq(connection_config))
      # The original hash should still have the original database value
      expect(adapter.connection_config[:database]).to(eq('myapp'))
    end
  end

  describe '#create (via create_tenant)' do
    let(:connection) { double('Connection') }

    before do
      allow(ActiveRecord::Base).to(receive(:connection).and_return(connection))
      allow(Apartment::Instrumentation).to(receive(:instrument))
    end

    it 'executes CREATE DATABASE with quoted environmentified name' do
      allow(connection).to(receive(:quote_table_name).with('acme').and_return('"acme"'))
      expect(connection).to(receive(:execute).with('CREATE DATABASE "acme"'))

      adapter.create('acme')
    end

    it 'quotes tenant names that need escaping' do
      allow(connection).to(receive(:quote_table_name).with('my-tenant').and_return('"my-tenant"'))
      expect(connection).to(receive(:execute).with('CREATE DATABASE "my-tenant"'))

      adapter.create('my-tenant')
    end

    it 'uses environmentified name for CREATE DATABASE' do
      reconfigure(environmentify_strategy: :prepend)
      allow(Rails).to(receive(:env).and_return('test'))
      allow(connection).to(receive(:quote_table_name).with('test_acme').and_return('"test_acme"'))
      expect(connection).to(receive(:execute).with('CREATE DATABASE "test_acme"'))

      adapter.create('acme')
    end
  end

  describe '#drop (via drop_tenant)' do
    let(:connection) { double('Connection') }
    let(:pool_manager) { Apartment.pool_manager }

    before do
      allow(ActiveRecord::Base).to(receive(:connection).and_return(connection))
      allow(Apartment::Instrumentation).to(receive(:instrument))
      allow(pool_manager).to(receive(:remove).and_return(nil))
    end

    it 'executes DROP DATABASE IF EXISTS with quoted environmentified name' do
      allow(connection).to(receive(:quote_table_name).with('acme').and_return('"acme"'))
      expect(connection).to(receive(:execute).with('DROP DATABASE IF EXISTS "acme"'))

      adapter.drop('acme')
    end

    it 'quotes tenant names that need escaping' do
      allow(connection).to(receive(:quote_table_name).with('my-tenant').and_return('"my-tenant"'))
      expect(connection).to(receive(:execute).with('DROP DATABASE IF EXISTS "my-tenant"'))

      adapter.drop('my-tenant')
    end

    it 'uses environmentified name for DROP DATABASE' do
      reconfigure(environmentify_strategy: :prepend)
      allow(Rails).to(receive(:env).and_return('test'))
      allow(connection).to(receive(:quote_table_name).with('test_acme').and_return('"test_acme"'))
      expect(connection).to(receive(:execute).with('DROP DATABASE IF EXISTS "test_acme"'))

      adapter.drop('acme')
    end
  end
end
