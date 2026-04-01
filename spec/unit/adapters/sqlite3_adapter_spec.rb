# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../lib/apartment/adapters/sqlite3_adapter'

# Minimal Rails stub for environmentify tests.
unless defined?(Rails)
  module Rails
    def self.env
      'test'
    end
  end
end

RSpec.describe(Apartment::Adapters::Sqlite3Adapter) do
  let(:connection_config) { { adapter: 'sqlite3', database: 'db/myapp.sqlite3' } }
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
    it 'returns config with database key set to file path' do
      result = adapter.resolve_connection_config('acme')

      expect(result['database']).to(eq('db/acme.sqlite3'))
    end

    it 'stringifies all config keys' do
      result = adapter.resolve_connection_config('acme')

      expect(result.keys).to(all(be_a(String)))
      expect(result['adapter']).to(eq('sqlite3'))
    end

    it 'uses environmentify with :prepend strategy' do
      reconfigure(environmentify_strategy: :prepend)
      allow(Rails).to(receive(:env).and_return('staging'))

      result = adapter.resolve_connection_config('acme')

      expect(result['database']).to(eq('db/staging_acme.sqlite3'))
    end

    it 'uses environmentify with :append strategy' do
      reconfigure(environmentify_strategy: :append)
      allow(Rails).to(receive(:env).and_return('staging'))

      result = adapter.resolve_connection_config('acme')

      expect(result['database']).to(eq('db/acme_staging.sqlite3'))
    end

    it 'uses environmentify with callable strategy' do
      reconfigure(environmentify_strategy: ->(t) { "custom_#{t}" })

      result = adapter.resolve_connection_config('acme')

      expect(result['database']).to(eq('db/custom_acme.sqlite3'))
    end

    it 'preserves all original connection config keys' do
      config = { adapter: 'sqlite3', database: 'db/app.sqlite3', pool: 5, timeout: 5000 }
      local_adapter = described_class.new(config)

      result = local_adapter.resolve_connection_config('tenant1')

      expect(result['pool']).to(eq(5))
      expect(result['timeout']).to(eq(5000))
    end

    it 'does not mutate the original connection_config' do
      adapter.resolve_connection_config('acme')

      expect(adapter.connection_config).to(eq(connection_config))
      expect(adapter.connection_config[:database]).to(eq('db/myapp.sqlite3'))
    end
  end

  describe '#database_file (via resolve_connection_config)' do
    it 'constructs path from base_config database directory + environmentified tenant + .sqlite3' do
      config = { adapter: 'sqlite3', database: '/var/data/app.sqlite3' }
      local_adapter = described_class.new(config)

      result = local_adapter.resolve_connection_config('tenant1')

      expect(result['database']).to(eq('/var/data/tenant1.sqlite3'))
    end

    it 'falls back to db/ directory when base_config has no database key' do
      local_adapter = described_class.new({ adapter: 'sqlite3' })

      result = local_adapter.resolve_connection_config('acme')

      expect(result['database']).to(eq('db/acme.sqlite3'))
    end
  end

  describe '#create (via create_tenant)' do
    before do
      allow(Apartment::Instrumentation).to(receive(:instrument))
    end

    it 'calls FileUtils.mkdir_p on the database file directory' do
      expect(FileUtils).to(receive(:mkdir_p).with('db'))

      adapter.create('acme')
    end

    it 'creates directory for nested database paths' do
      config = { adapter: 'sqlite3', database: '/var/data/tenants/app.sqlite3' }
      local_adapter = described_class.new(config)

      expect(FileUtils).to(receive(:mkdir_p).with('/var/data/tenants'))

      local_adapter.create('acme')
    end
  end

  describe '#drop (via drop_tenant)' do
    let(:pool_manager) { Apartment.pool_manager }

    before do
      allow(Apartment::Instrumentation).to(receive(:instrument))
      allow(pool_manager).to(receive(:remove_tenant).and_return([]))
      allow(Apartment).to(receive(:deregister_shard))
    end

    it 'calls FileUtils.rm_f on the database file' do
      expect(FileUtils).to(receive(:rm_f).with('db/acme.sqlite3'))

      adapter.drop('acme')
    end

    it 'does not raise if the file does not exist (rm_f is idempotent)' do
      allow(FileUtils).to(receive(:rm_f))

      expect { adapter.drop('acme') }.not_to(raise_error)
    end

    it 'uses environmentified name for file path' do
      reconfigure(environmentify_strategy: :prepend)
      allow(Rails).to(receive(:env).and_return('test'))

      expect(FileUtils).to(receive(:rm_f).with('db/test_acme.sqlite3'))

      adapter.drop('acme')
    end
  end
end
