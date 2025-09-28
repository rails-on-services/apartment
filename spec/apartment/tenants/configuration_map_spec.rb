# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apartment::Tenants::ConfigurationMap do
  let(:config_map) { described_class.new }

  # Helper method to handle database-specific quoting
  def expect_quoted_tenant(actual, expected_name)
    # MySQL uses backticks, PostgreSQL uses double quotes, SQLite no quotes
    expect(actual).to eq("\"#{expected_name}\"").or eq("`#{expected_name}`").or eq(expected_name)
  end

  before(:all) do
    Apartment.configure do |config|
      config.default_tenant = 'public'
      config.tenant_strategy = :schema
      config.tenants_provider = -> { %w[tenant1 tenant2] }
    end
  end

  describe 'initialization' do
    it 'starts with empty configurations' do
      expect(config_map.instance_variable_get(:@configuration_map)).to be_empty
    end
  end

  describe '#add_or_replace' do
    context 'with string tenant configuration' do
      it 'adds string tenant correctly' do
        config_map.add_or_replace('simple_tenant')

        expect_quoted_tenant(config_map['simple_tenant'], 'simple_tenant')
      end

      it 'replaces existing string tenant' do
        config_map.add_or_replace('tenant1')
        config_map.add_or_replace('tenant1')

        expect(config_map['tenant1']).to eq('"tenant1"')
      end
    end

    context 'with hash tenant configuration' do
      let(:tenant_hash) do
        {
          'tenant' => 'complex_tenant',
          'database' => 'complex_db'
        }
      end

      it 'adds hash tenant correctly' do
        config_map.add_or_replace(tenant_hash)

        expect(config_map['complex_tenant']).to eq('complex_db')
      end

      it 'handles shard strategy' do
        allow(Apartment.config).to receive(:tenant_strategy).and_return(:shard)

        shard_config = {
          'tenant' => 'shard_tenant',
          'shard' => 'shard_1'
        }

        config_map.add_or_replace(shard_config)

        expect(config_map['shard_tenant']).to eq('shard_1')
      end

      it 'handles database_config strategy' do
        allow(Apartment.config).to receive(:tenant_strategy).and_return(:database_config)

        db_config = {
          'tenant' => 'custom_tenant',
          'adapter' => 'postgresql',
          'database' => 'custom_db'
        }

        config_map.add_or_replace(db_config)

        result = config_map['custom_tenant']
        expect(result['adapter']).to eq('postgresql')
        expect(result['database']).to eq('custom_db')
      end
    end

    context 'with environmentify strategy' do
      before do
        allow(Apartment.config).to receive(:environmentify_strategy).and_return(:prepend)
        allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new('test'))
      end

      it 'applies prepend environmentify' do
        config_map.add_or_replace('env_tenant')

        expect(config_map['env_tenant']).to eq('"test_env_tenant"')
      end

      it 'applies append environmentify when strategy is append' do
        allow(Apartment.config).to receive(:environmentify_strategy).and_return(:append)

        config_map.add_or_replace('env_tenant')

        expect(config_map['env_tenant']).to eq('"env_tenant_test"')
      end

      it 'applies callable environmentify strategy' do
        custom_strategy = ->(tenant) { "custom_#{tenant}_suffix" }
        allow(Apartment.config).to receive(:environmentify_strategy).and_return(custom_strategy)

        config_map.add_or_replace('callable_tenant')

        expect(config_map['callable_tenant']).to eq('"custom_callable_tenant_suffix"')
      end
    end
  end

  describe '#[]' do
    before do
      config_map.add_or_replace('test_tenant')
    end

    it 'retrieves existing tenant configuration' do
      expect(config_map['test_tenant']).to eq('"test_tenant"')
    end

    it 'returns nil for non-existent tenant' do
      expect(config_map['nonexistent']).to be_nil
    end
  end

  describe 'private methods' do
    describe '#tenant_name_from_config' do
      it 'extracts tenant name from string' do
        name = config_map.send(:tenant_name_from_config, 'string_tenant')
        expect(name).to eq('string_tenant')
      end

      it 'extracts tenant name from hash' do
        hash_config = { 'tenant' => 'hash_tenant', 'database' => 'db' }
        name = config_map.send(:tenant_name_from_config, hash_config)
        expect(name).to eq('hash_tenant')
      end

      it 'returns nil for hash without tenant key' do
        hash_config = { 'database' => 'db_only' }
        name = config_map.send(:tenant_name_from_config, hash_config)
        expect(name).to be_nil
      end
    end

    describe '#tenant_config_from_hash' do
      context 'with schema strategy' do
        it 'returns environmentified tenant name' do
          hash_config = { 'tenant' => 'schema_tenant' }
          result = config_map.send(:tenant_config_from_hash, hash_config, tenant_strategy: :schema)

          expect(result).to eq('"schema_tenant"')
        end
      end

      context 'with database_name strategy' do
        it 'returns database value' do
          hash_config = { 'tenant' => 'db_tenant', 'database' => 'custom_db' }
          result = config_map.send(:tenant_config_from_hash, hash_config, tenant_strategy: :database_name)

          expect(result).to eq('custom_db')
        end
      end

      context 'with shard strategy' do
        it 'returns shard value' do
          hash_config = { 'tenant' => 'shard_tenant', 'shard' => 'shard_2' }
          result = config_map.send(:tenant_config_from_hash, hash_config, tenant_strategy: :shard)

          expect(result).to eq('shard_2')
        end
      end

      context 'with database_config strategy' do
        it 'returns the entire configuration hash without tenant key' do
          hash_config = {
            'tenant' => 'config_tenant',
            'adapter' => 'postgresql',
            'database' => 'tenant_db',
            'host' => 'localhost'
          }
          result = config_map.send(:tenant_config_from_hash, hash_config, tenant_strategy: :database_config)

          expected = {
            'adapter' => 'postgresql',
            'database' => 'tenant_db',
            'host' => 'localhost'
          }
          expect(result).to eq(expected)
        end
      end
    end

    describe '#environmentify_tenant' do
      let(:tenant_name) { 'test_tenant' }

      before do
        allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new('development'))
      end

      context 'with prepend strategy' do
        it 'prepends environment to tenant name' do
          result = config_map.send(:environmentify_tenant, tenant_name, tenant_strategy: :schema)
          allow(Apartment.config).to receive(:environmentify_strategy).and_return(:prepend)

          result = config_map.send(:environmentify_tenant, result, tenant_strategy: :schema)
          expect(result).to eq('development_test_tenant')
        end
      end

      context 'with append strategy' do
        it 'appends environment to tenant name' do
          allow(Apartment.config).to receive(:environmentify_strategy).and_return(:append)

          result = config_map.send(:environmentify_tenant, tenant_name, tenant_strategy: :schema)
          expect(result).to eq('test_tenant_development')
        end
      end

      context 'with callable strategy' do
        it 'applies callable transformation' do
          callable = ->(tenant) { "transformed_#{tenant}" }
          allow(Apartment.config).to receive(:environmentify_strategy).and_return(callable)

          result = config_map.send(:environmentify_tenant, tenant_name, tenant_strategy: :schema)
          expect(result).to eq('transformed_test_tenant')
        end
      end

      context 'with nil strategy' do
        it 'returns tenant name unchanged' do
          allow(Apartment.config).to receive(:environmentify_strategy).and_return(nil)

          result = config_map.send(:environmentify_tenant, tenant_name, tenant_strategy: :schema)
          expect(result).to eq('test_tenant')
        end
      end
    end

    describe '#quote_tenant_name' do
      it 'quotes PostgreSQL tenant names' do
        result = config_map.send(:quote_tenant_name, 'postgres_tenant', 'postgresql')
        expect(result).to eq('"postgres_tenant"')
      end

      it 'quotes MySQL tenant names for mysql2 adapter' do
        result = config_map.send(:quote_tenant_name, 'mysql_tenant', 'mysql2')
        expect(result).to eq('`mysql_tenant`')
      end

      it 'quotes MySQL tenant names for trilogy adapter' do
        result = config_map.send(:quote_tenant_name, 'trilogy_tenant', 'trilogy')
        expect(result).to eq('`trilogy_tenant`')
      end

      it 'does not quote SQLite tenant names' do
        result = config_map.send(:quote_tenant_name, 'sqlite_tenant', 'sqlite3')
        expect(result).to eq('sqlite_tenant')
      end

      it 'does not quote unknown adapter tenant names' do
        result = config_map.send(:quote_tenant_name, 'unknown_tenant', 'unknown_adapter')
        expect(result).to eq('unknown_tenant')
      end
    end
  end

  describe 'integration behavior' do
    it 'works with complex tenant configurations' do
      # Test a realistic scenario with mixed tenant types
      config_map.add_or_replace('simple_tenant')
      config_map.add_or_replace({
        'tenant' => 'complex_tenant',
        'database' => 'complex_db'
      })

      tenant_config = config_map['simple_tenant']
        # MySQL uses backticks, PostgreSQL uses double quotes
        expect(tenant_config).to eq('"simple_tenant"').or eq('`simple_tenant`')
      expect(config_map['complex_tenant']).to eq('complex_db')
    end

    it 'handles tenant replacement correctly' do
      config_map.add_or_replace('replaceable_tenant')
      original_config = config_map['replaceable_tenant']

      config_map.add_or_replace({
        'tenant' => 'replaceable_tenant',
        'database' => 'new_database'
      })

      expect(config_map['replaceable_tenant']).not_to eq(original_config)
      expect(config_map['replaceable_tenant']).to eq('new_database')
    end
  end
end