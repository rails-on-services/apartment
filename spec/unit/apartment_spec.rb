# frozen_string_literal: true

require 'spec_helper'

# Minimal ActiveRecord stub for unit tests (no Rails loaded).
unless defined?(ActiveRecord::Base)
  module ActiveRecord
    class Base
      def self.connection_db_config
        raise('Stub: ActiveRecord::Base.connection_db_config not mocked')
      end
    end
  end
end

RSpec.describe(Apartment) do
  describe '.adapter' do
    context 'when not configured' do
      it 'raises ConfigurationError' do
        expect { described_class.adapter }.to(raise_error(
                                                Apartment::ConfigurationError, /not configured/
                                              ))
      end
    end

    context 'when manually set' do
      before do
        described_class.configure do |config|
          config.tenant_strategy = :schema
          config.tenants_provider = -> { [] }
        end
      end

      it 'returns the manually set adapter' do
        mock = double('Adapter')
        described_class.adapter = mock
        expect(described_class.adapter).to(eq(mock))
      end
    end

    context 'caching behavior' do
      before do
        described_class.configure do |config|
          config.tenant_strategy = :schema
          config.tenants_provider = -> { [] }
        end
      end

      it 'returns the same instance on subsequent calls' do
        mock = double('Adapter')
        described_class.adapter = mock
        expect(described_class.adapter).to(equal(described_class.adapter))
      end
    end
  end

  describe '.tenant_names' do
    it 'delegates to config.tenants_provider.call' do
      tenants = %w[acme widgets]
      described_class.configure do |config|
        config.tenant_strategy = :schema
        config.tenants_provider = -> { tenants }
      end

      expect(described_class.tenant_names).to(eq(%w[acme widgets]))
    end

    it 'raises ConfigurationError when not configured' do
      described_class.clear_config
      expect { described_class.tenant_names }.to(raise_error(Apartment::ConfigurationError, /not configured/))
    end
  end

  describe '.excluded_models' do
    it 'delegates to config.excluded_models' do
      described_class.configure do |config|
        config.tenant_strategy = :schema
        config.tenants_provider = -> { [] }
        config.excluded_models = %w[Account]
      end

      expect(described_class.excluded_models).to(eq(%w[Account]))
    end

    it 'raises ConfigurationError when not configured' do
      described_class.clear_config
      expect { described_class.excluded_models }.to(raise_error(Apartment::ConfigurationError, /not configured/))
    end
  end

  describe '.clear_config' do
    it 'resets the adapter' do
      described_class.configure do |config|
        config.tenant_strategy = :schema
        config.tenants_provider = -> { [] }
      end
      described_class.adapter = double('Adapter')

      described_class.clear_config

      expect { described_class.adapter }.to(raise_error(Apartment::ConfigurationError))
    end

    it 'restores convention-path table_name_prefix on pinned models' do
      klass = Class.new(ActiveRecord::Base) do
        include Apartment::Model
      end
      stub_const('ConventionTeardown', klass)
      allow(klass).to(receive(:table_name_prefix).and_return(''))
      allow(klass).to(receive(:table_name_prefix=))
      allow(klass).to(receive(:reset_table_name))

      ConventionTeardown.pin_tenant
      # Simulate convention-path qualification
      klass.instance_variable_set(:@apartment_pinned_processed, true)
      klass.instance_variable_set(:@apartment_qualification_path, :convention)
      klass.instance_variable_set(:@apartment_original_table_name_prefix, 'myapp_')

      described_class.clear_config

      expect(klass).to(have_received(:table_name_prefix=).with('myapp_'))
      expect(klass).to(have_received(:reset_table_name))
      expect(klass.instance_variable_defined?(:@apartment_pinned_processed)).to(be(false))
      expect(klass.instance_variable_defined?(:@apartment_qualification_path)).to(be(false))
      expect(klass.instance_variable_defined?(:@apartment_original_table_name_prefix)).to(be(false))
    end

    it 'restores explicit-path table_name on pinned models' do
      klass = Class.new(ActiveRecord::Base) do
        include Apartment::Model
      end
      stub_const('ExplicitTeardown', klass)
      allow(klass).to(receive(:table_name=))

      ExplicitTeardown.pin_tenant
      klass.instance_variable_set(:@apartment_pinned_processed, true)
      klass.instance_variable_set(:@apartment_qualification_path, :explicit)
      klass.instance_variable_set(:@apartment_original_table_name, 'custom_jobs')

      described_class.clear_config

      expect(klass).to(have_received(:table_name=).with('custom_jobs'))
      expect(klass.instance_variable_defined?(:@apartment_pinned_processed)).to(be(false))
      expect(klass.instance_variable_defined?(:@apartment_original_table_name)).to(be(false))
    end

    it 'handles separate-pool path (nil qualification_path) without error' do
      klass = Class.new(ActiveRecord::Base) do
        include Apartment::Model
      end
      stub_const('SeparatePoolTeardown', klass)

      SeparatePoolTeardown.pin_tenant
      klass.instance_variable_set(:@apartment_pinned_processed, true)
      # No @apartment_qualification_path set (separate-pool path)

      expect { described_class.clear_config }.not_to(raise_error)
      expect(klass.instance_variable_defined?(:@apartment_pinned_processed)).to(be(false))
    end
  end

  describe '.configure' do
    it 'resets the adapter so it will be rebuilt' do
      described_class.configure do |config|
        config.tenant_strategy = :schema
        config.tenants_provider = -> { [] }
      end
      described_class.adapter = double('Adapter')

      # Reconfiguring should clear the cached adapter
      described_class.configure do |config|
        config.tenant_strategy = :schema
        config.tenants_provider = -> { [] }
      end

      # The adapter ivar should be nil (cleared), so lazy build will be attempted
      # on next access. Verify the old mock is gone by checking the ivar directly.
      expect(described_class.instance_variable_get(:@adapter)).to(be_nil)
    end
  end

  describe '.pool_reaper' do
    it 'is nil before configure' do
      expect(described_class.pool_reaper).to(be_nil)
    end

    it 'is an instance of PoolReaper after configure' do
      described_class.configure do |config|
        config.tenant_strategy = :schema
        config.tenants_provider = -> { [] }
      end
      expect(described_class.pool_reaper).to(be_a(Apartment::PoolReaper))
    end

    it 'is running after configure' do
      described_class.configure do |config|
        config.tenant_strategy = :schema
        config.tenants_provider = -> { [] }
      end
      expect(described_class.pool_reaper).to(be_running)
    end

    it 'is nil after clear_config' do
      described_class.configure do |config|
        config.tenant_strategy = :schema
        config.tenants_provider = -> { [] }
      end
      described_class.clear_config
      expect(described_class.pool_reaper).to(be_nil)
    end
  end

  describe '.configure teardown protection' do
    it 'completes reconfigure even if reaper stop raises' do
      described_class.configure do |config|
        config.tenant_strategy = :schema
        config.tenants_provider = -> { [] }
      end

      allow(described_class.pool_reaper).to(receive(:stop).and_raise(RuntimeError, 'timer boom'))

      expect do
        described_class.configure do |config|
          config.tenant_strategy = :schema
          config.tenants_provider = -> { [] }
          config.default_tenant = 'new_default'
        end
      end.not_to(raise_error)

      expect(described_class.config.default_tenant).to(eq('new_default'))
    end
  end

  describe 'build_adapter (private)' do
    before do
      described_class.configure do |config|
        config.tenant_strategy = :schema
        config.tenants_provider = -> { [] }
      end
    end

    context 'strategy resolution' do
      let(:db_config) { double('db_config', adapter: 'postgresql', configuration_hash: { adapter: 'postgresql' }) }

      before do
        allow(ActiveRecord::Base).to(receive(:connection_db_config).and_return(db_config))
      end

      it 'requires postgresql_schema_adapter for :schema strategy' do
        adapter = described_class.send(:build_adapter)
        expect(adapter).to(be_a(Apartment::Adapters::PostgresqlSchemaAdapter))
      end

      context 'with :database_name strategy' do
        before do
          described_class.configure do |config|
            config.tenant_strategy = :database_name
            config.tenants_provider = -> { [] }
          end
        end

        it 'instantiates PostgresqlDatabaseAdapter for postgresql' do
          allow(db_config).to(receive_messages(adapter: 'postgresql', configuration_hash: { adapter: 'postgresql' }))

          adapter = described_class.send(:build_adapter)
          expect(adapter).to(be_a(Apartment::Adapters::PostgresqlDatabaseAdapter))
        end

        it 'instantiates PostgresqlDatabaseAdapter for postgis' do
          allow(db_config).to(receive_messages(adapter: 'postgis', configuration_hash: { adapter: 'postgis' }))

          adapter = described_class.send(:build_adapter)
          expect(adapter).to(be_a(Apartment::Adapters::PostgresqlDatabaseAdapter))
        end

        it 'instantiates Mysql2Adapter for mysql2' do
          allow(db_config).to(receive_messages(adapter: 'mysql2', configuration_hash: { adapter: 'mysql2' }))

          adapter = described_class.send(:build_adapter)
          expect(adapter).to(be_a(Apartment::Adapters::Mysql2Adapter))
        end

        it 'instantiates TrilogyAdapter for trilogy' do
          allow(db_config).to(receive_messages(adapter: 'trilogy', configuration_hash: { adapter: 'trilogy' }))

          adapter = described_class.send(:build_adapter)
          expect(adapter).to(be_a(Apartment::Adapters::TrilogyAdapter))
        end

        it 'instantiates Sqlite3Adapter for sqlite3' do
          allow(db_config).to(receive_messages(adapter: 'sqlite3', configuration_hash: { adapter: 'sqlite3' }))

          adapter = described_class.send(:build_adapter)
          expect(adapter).to(be_a(Apartment::Adapters::Sqlite3Adapter))
        end

        it 'raises AdapterNotFound for unknown database adapter' do
          allow(db_config).to(receive(:adapter).and_return('oracle'))
          expect { described_class.send(:build_adapter) }.to(
            raise_error(Apartment::AdapterNotFound, /No adapter for database: oracle/)
          )
        end
      end

      context 'with unsupported strategy' do
        it 'raises AdapterNotFound for :shard strategy' do
          described_class.configure do |config|
            config.tenant_strategy = :shard
            config.tenants_provider = -> { [] }
          end
          expect { described_class.send(:build_adapter) }.to(
            raise_error(Apartment::AdapterNotFound, /Strategy shard not yet implemented/)
          )
        end

        it 'raises AdapterNotFound for :database_config strategy' do
          described_class.configure do |config|
            config.tenant_strategy = :database_config
            config.tenants_provider = -> { [] }
          end
          expect { described_class.send(:build_adapter) }.to(
            raise_error(Apartment::AdapterNotFound, /Strategy database_config not yet implemented/)
          )
        end
      end
    end

    context 'with a concrete adapter class available' do
      let(:db_config) { double('db_config', adapter: 'postgresql', configuration_hash: { adapter: 'postgresql' }) }
      let(:fake_adapter_instance) { double('adapter_instance') }
      let(:fake_adapter_class) { class_double('Apartment::Adapters::PostgresqlSchemaAdapter').as_stubbed_const }

      before do
        allow(ActiveRecord::Base).to(receive(:connection_db_config).and_return(db_config))
        allow(described_class).to(receive(:require_relative))
        stub_const('Apartment::Adapters::PostgresqlSchemaAdapter', fake_adapter_class)
        allow(fake_adapter_class).to(receive(:new).and_return(fake_adapter_instance))
      end

      it 'instantiates the adapter with the connection configuration hash' do
        result = described_class.send(:build_adapter)
        expect(fake_adapter_class).to(have_received(:new).with({ adapter: 'postgresql' }))
        expect(result).to(eq(fake_adapter_instance))
      end

      it 'caches the adapter on subsequent .adapter calls' do
        first = described_class.adapter
        second = described_class.adapter
        expect(first).to(equal(second))
        expect(fake_adapter_class).to(have_received(:new).once)
      end
    end
  end

  describe '.deregister_shard' do
    before do
      described_class.configure do |config|
        config.tenant_strategy = :schema
        config.tenants_provider = -> { [] }
      end
    end

    it 'calls remove_connection_pool with the role parsed from the composite key' do
      handler = instance_double('ActiveRecord::ConnectionAdapters::ConnectionHandler')
      allow(ActiveRecord::Base).to(receive(:connection_handler).and_return(handler))
      allow(handler).to(receive(:remove_connection_pool))
      allow(ActiveRecord).to(receive(:writing_role).and_return(:writing))

      described_class.deregister_shard('acme:db_manager')

      prefix = described_class.config.shard_key_prefix
      expect(handler).to(have_received(:remove_connection_pool).with(
                           'ActiveRecord::Base',
                           role: :db_manager,
                           shard: :"#{prefix}_acme:db_manager"
                         ))
    end

    it 'falls back to writing_role when pool_key has no colon' do
      handler = instance_double('ActiveRecord::ConnectionAdapters::ConnectionHandler')
      allow(ActiveRecord::Base).to(receive(:connection_handler).and_return(handler))
      allow(handler).to(receive(:remove_connection_pool))
      allow(ActiveRecord).to(receive(:writing_role).and_return(:writing))

      described_class.deregister_shard('acme')

      prefix = described_class.config.shard_key_prefix
      expect(handler).to(have_received(:remove_connection_pool).with(
                           'ActiveRecord::Base',
                           role: :writing,
                           shard: :"#{prefix}_acme"
                         ))
    end

    it 'is a no-op when config is nil' do
      described_class.clear_config
      expect { described_class.deregister_shard('acme') }.not_to(raise_error)
    end
  end

  describe '.detect_database_adapter (private)' do
    it 'returns the adapter string from ActiveRecord connection config' do
      db_config = double('db_config', adapter: 'postgresql')
      allow(ActiveRecord::Base).to(receive(:connection_db_config).and_return(db_config))

      result = described_class.send(:detect_database_adapter)
      expect(result).to(eq('postgresql'))
    end
  end
end
