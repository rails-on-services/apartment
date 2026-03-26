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
      # Since concrete classes don't exist, this will raise LoadError
      # We verify the old mock is gone by checking the ivar directly
      expect(described_class.instance_variable_get(:@adapter)).to(be_nil)
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
        expect(adapter).to(be_a(Apartment::Adapters::PostgreSQLSchemaAdapter))
      end

      context 'with :database_name strategy' do
        before do
          described_class.configure do |config|
            config.tenant_strategy = :database_name
            config.tenants_provider = -> { [] }
          end
        end

        it 'instantiates PostgreSQLDatabaseAdapter for postgresql' do
          allow(db_config).to(receive_messages(adapter: 'postgresql', configuration_hash: { adapter: 'postgresql' }))

          adapter = described_class.send(:build_adapter)
          expect(adapter).to(be_a(Apartment::Adapters::PostgreSQLDatabaseAdapter))
        end

        it 'instantiates PostgreSQLDatabaseAdapter for postgis' do
          allow(db_config).to(receive_messages(adapter: 'postgis', configuration_hash: { adapter: 'postgis' }))

          adapter = described_class.send(:build_adapter)
          expect(adapter).to(be_a(Apartment::Adapters::PostgreSQLDatabaseAdapter))
        end

        it 'instantiates MySQL2Adapter for mysql2' do
          allow(db_config).to(receive_messages(adapter: 'mysql2', configuration_hash: { adapter: 'mysql2' }))

          adapter = described_class.send(:build_adapter)
          expect(adapter).to(be_a(Apartment::Adapters::MySQL2Adapter))
        end

        it 'instantiates TrilogyAdapter for trilogy' do
          allow(db_config).to(receive_messages(adapter: 'trilogy', configuration_hash: { adapter: 'trilogy' }))

          adapter = described_class.send(:build_adapter)
          expect(adapter).to(be_a(Apartment::Adapters::TrilogyAdapter))
        end

        it 'attempts to load sqlite3_adapter for sqlite3' do
          allow(db_config).to(receive(:adapter).and_return('sqlite3'))
          # V3 file exists but v4 constant (SQLite3Adapter) doesn't — raises NameError
          expect { described_class.send(:build_adapter) }.to(raise_error(NameError, /SQLite3Adapter/))
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
      let(:fake_adapter_class) { class_double('Apartment::Adapters::PostgreSQLSchemaAdapter').as_stubbed_const }

      before do
        allow(ActiveRecord::Base).to(receive(:connection_db_config).and_return(db_config))
        allow(described_class).to(receive(:require_relative))
        stub_const('Apartment::Adapters::PostgreSQLSchemaAdapter', fake_adapter_class)
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

  describe '.detect_database_adapter (private)' do
    it 'returns the adapter string from ActiveRecord connection config' do
      db_config = double('db_config', adapter: 'postgresql')
      allow(ActiveRecord::Base).to(receive(:connection_db_config).and_return(db_config))

      result = described_class.send(:detect_database_adapter)
      expect(result).to(eq('postgresql'))
    end
  end
end
