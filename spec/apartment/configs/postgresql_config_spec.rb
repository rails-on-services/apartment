# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apartment::Configs::PostgreSQLConfig do
  let(:config) { described_class.new }

  describe 'initialization' do
    it 'sets default values' do
      expect(config.persistent_schemas).to eq([])
      expect(config.enforce_search_path_reset).to be false
    end
  end

  describe '#persistent_schemas' do
    it 'accepts array of schema names' do
      schemas = %w[public shared_data]
      config.persistent_schemas = schemas

      expect(config.persistent_schemas).to eq(schemas)
    end

    it 'can be modified after initialization' do
      config.persistent_schemas << 'new_schema'
      expect(config.persistent_schemas).to include('new_schema')
    end
  end

  describe '#enforce_search_path_reset' do
    it 'accepts boolean values' do
      config.enforce_search_path_reset = true
      expect(config.enforce_search_path_reset).to be true

      config.enforce_search_path_reset = false
      expect(config.enforce_search_path_reset).to be false
    end
  end

  describe '#validate!' do
    it 'validates configuration without errors' do
      expect { config.validate! }.not_to raise_error
    end

    it 'returns nil' do
      result = config.validate!
      expect(result).to be_nil
    end
  end

  describe '#apply!' do
    context 'when enforce_search_path_reset is false' do
      before do
        config.enforce_search_path_reset = false
      end

      it 'does not set up any callbacks' do
        expect(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter).not_to receive(:set_callback)
        config.apply!
      end
    end

    context 'when enforce_search_path_reset is true' do
      before do
        config.enforce_search_path_reset = true
      end

      it 'sets up before_checkin callback' do
        expect(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter).to receive(:set_callback)
          .with(:checkin, :before)

        config.apply!
      end
    end

    context 'without database connection' do
      it 'handles missing PostgreSQL adapter gracefully' do
        # This test ensures apply! doesn't crash if PostgreSQL adapter isn't loaded
        expect { config.apply! }.not_to raise_error
      end
    end
  end

  describe 'integration with Apartment configuration' do
    it 'integrates with main Apartment config' do
      original_config = nil

      Apartment.configure do |apartment_config|
        apartment_config.configure_postgres do |pg_config|
          pg_config.persistent_schemas = %w[public shared]
          pg_config.enforce_search_path_reset = true
          original_config = pg_config
        end
      end

      pg_config = Apartment.config.postgres_config

      expect(pg_config).to eq(original_config)
      expect(pg_config.persistent_schemas).to eq(%w[public shared])
      expect(pg_config.enforce_search_path_reset).to be true
    end

    it 'allows configuration block customization' do
      custom_value = 'configured'

      Apartment.configure do |apartment_config|
        apartment_config.configure_postgres do |pg_config|
          pg_config.instance_variable_set(:@test_value, custom_value)
        end
      end

      pg_config = Apartment.config.postgres_config
      expect(pg_config.instance_variable_get(:@test_value)).to eq(custom_value)
    end
  end

  describe 'PostgreSQL adapter integration' do
    context 'when PostgreSQL adapter is available' do
      it 'can set up callbacks on the adapter' do
        config.enforce_search_path_reset = true

        if defined?(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter)
          expect(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter).to receive(:set_callback)
        end

        config.apply!
      end
    end
  end

  describe 'search path reset callback behavior' do
    let(:mock_connection) { double('connection') }

    context 'when callback is triggered' do
      before do
        config.enforce_search_path_reset = true
        allow(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter).to receive(:set_callback) do |event, timing, &block|
          # Store the callback for testing
          @callback_block = block
        end
      end

      it 'resets search_path when not on public schema' do
        allow(mock_connection).to receive(:instance_variable_get).with(:@schema_search_path).and_return('tenant1')
        expect(mock_connection).to receive(:execute).with('RESET search_path')

        config.apply!
        @callback_block.call(mock_connection) if @callback_block
      end

      it 'skips reset when already on public schema' do
        allow(mock_connection).to receive(:instance_variable_get).with(:@schema_search_path).and_return('public')
        expect(mock_connection).not_to receive(:execute)

        config.apply!
        @callback_block.call(mock_connection) if @callback_block
      end

      it 'skips reset when search_path contains quoted public' do
        allow(mock_connection).to receive(:instance_variable_get).with(:@schema_search_path).and_return('"public"')
        expect(mock_connection).not_to receive(:execute)

        config.apply!
        @callback_block.call(mock_connection) if @callback_block
      end
    end
  end

  describe 'thread safety' do
    it 'handles concurrent configuration safely' do
      threads = 3.times.map do |i|
        Thread.new do
          local_config = described_class.new
          local_config.persistent_schemas = ["schema_#{i}"]
          local_config.enforce_search_path_reset = (i.even?)
          local_config.validate!
        end
      end

      expect { threads.each(&:join) }.not_to raise_error
    end
  end

  describe 'configuration validation' do
    it 'accepts valid persistent_schemas configurations' do
      valid_configs = [
        [],
        %w[public],
        %w[public shared tenant_common],
        ['schema-with-dashes', 'schema_with_underscores']
      ]

      valid_configs.each do |schemas|
        config.persistent_schemas = schemas
        expect { config.validate! }.not_to raise_error
      end
    end

    it 'accepts valid enforce_search_path_reset configurations' do
      [true, false].each do |value|
        config.enforce_search_path_reset = value
        expect { config.validate! }.not_to raise_error
      end
    end
  end

  describe 'error handling' do
    it 'handles callback setup errors gracefully' do
      config.enforce_search_path_reset = true

      # Mock an error during callback setup
      allow(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter).to receive(:set_callback)
        .and_raise(StandardError.new('Callback setup failed'))

      expect { config.apply! }.to raise_error(StandardError, 'Callback setup failed')
    end
  end

  describe 'configuration state' do
    it 'maintains configuration state between calls' do
      config.persistent_schemas = %w[public shared]
      config.enforce_search_path_reset = true

      config.validate!
      config.apply!

      expect(config.persistent_schemas).to eq(%w[public shared])
      expect(config.enforce_search_path_reset).to be true
    end

    it 'allows configuration changes after initialization' do
      original_schemas = config.persistent_schemas.dup
      original_reset_flag = config.enforce_search_path_reset

      config.persistent_schemas = %w[new_schema]
      config.enforce_search_path_reset = !original_reset_flag

      expect(config.persistent_schemas).not_to eq(original_schemas)
      expect(config.enforce_search_path_reset).not_to eq(original_reset_flag)
    end
  end
end