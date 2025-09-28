# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apartment::DatabaseConfigurations do
  before(:all) do
    Apartment.configure do |config|
      config.default_tenant = 'public'
      config.tenant_strategy = :schema
      config.tenants_provider = -> { %w[tenant1 tenant2 tenant3] }
    end
  end

  describe '.primary_or_first_db_config' do
    it 'returns the primary database configuration' do
      db_config = described_class.primary_or_first_db_config

      expect(db_config).to be_present
      expect(db_config).to respond_to(:configuration_hash)
    end
  end

  describe '.resolve_for_tenant' do
    let(:base_config) { :test }
    let(:tenant_name) { 'tenant1' }
    let(:role) { :writing }
    let(:shard) { :default }

    context 'with schema strategy' do
      before do
        allow(Apartment.config).to receive(:tenant_strategy).and_return(:schema)
      end

      it 'returns configuration with schema_search_path' do
        result = described_class.resolve_for_tenant(
          base_config,
          tenant: tenant_name,
          role: role,
          shard: shard
        )

        expect(result[:db_config].configuration_hash).to have_key(:schema_search_path)
        schema_path = result[:db_config].configuration_hash[:schema_search_path]
        # MySQL uses backticks, PostgreSQL uses double quotes
        expect(schema_path).to eq('"tenant1"').or eq('`tenant1`')
        expect(result[:role]).to eq(role)
        expect(result[:shard]).to eq(shard)
      end

      it 'preserves base configuration properties' do
        result = described_class.resolve_for_tenant(base_config, tenant: tenant_name)

        base_hash = Apartment.connection_class.configurations.resolve(base_config).configuration_hash
        result_hash = result[:db_config].configuration_hash

        # Should preserve all base properties except schema_search_path
        base_hash.each do |key, value|
          next if key == :schema_search_path

          expect(result_hash[key]).to eq(value)
        end
      end
    end

    context 'with database_name strategy' do
      before do
        allow(Apartment.config).to receive(:tenant_strategy).and_return(:database_name)
      end

      it 'returns configuration with updated database name' do
        result = described_class.resolve_for_tenant(
          base_config,
          tenant: tenant_name,
          role: role,
          shard: shard
        )

        expect(result[:db_config].configuration_hash).to have_key(:database)
        database_name = result[:db_config].configuration_hash[:database]
        # MySQL uses backticks, PostgreSQL uses double quotes
        expect(database_name).to eq('"tenant1"').or eq('`tenant1`')
        expect(result[:role]).to eq(role)
        expect(result[:shard]).to eq(shard)
      end
    end

    context 'with shard strategy' do
      before do
        allow(Apartment.config).to receive(:tenant_strategy).and_return(:shard)
      end

      it 'returns configuration with updated shard' do
        result = described_class.resolve_for_tenant(
          base_config,
          tenant: tenant_name,
          role: role,
          shard: shard
        )

        expect(result[:db_config]).to be_present
        expect(result[:role]).to eq(role)
        shard_name = result[:shard]
        # MySQL uses backticks, PostgreSQL uses double quotes
        expect(shard_name).to eq('"tenant1"').or eq('`tenant1`')
      end

      it 'uses provided shard if tenant config is nil' do
        allow(Apartment.tenant_configs).to receive(:[]).with(tenant_name).and_return(nil)

        result = described_class.resolve_for_tenant(
          base_config,
          tenant: tenant_name,
          role: role,
          shard: :custom_shard
        )

        expect(result[:shard]).to eq(:custom_shard)
      end
    end

    context 'with database_config strategy' do
      before do
        allow(Apartment.config).to receive(:tenant_strategy).and_return(:database_config)
        allow(Apartment.tenant_configs).to receive(:[]).with(tenant_name).and_return({
          'adapter' => 'postgresql',
          'database' => 'custom_tenant_db',
          'host' => 'custom_host'
        })
      end

      it 'returns configuration merged with tenant config' do
        result = described_class.resolve_for_tenant(
          base_config,
          tenant: tenant_name,
          role: role,
          shard: shard
        )

        config_hash = result[:db_config].configuration_hash

        expect(config_hash[:database]).to eq('custom_tenant_db')
        expect(config_hash[:host]).to eq('custom_host')
        expect(result[:role]).to eq(role)
        expect(result[:shard]).to eq(shard)
      end

      it 'preserves base config when tenant config matches' do
        base_config_hash = { 'adapter' => 'postgresql', 'database' => 'test_db' }
        allow(Apartment.connection_class.configurations).to receive(:resolve)
          .and_return(double(configuration_hash: base_config_hash, env_name: 'test', name: 'primary'))
        allow(Apartment.tenant_configs).to receive(:[]).with(tenant_name).and_return(base_config_hash)

        result = described_class.resolve_for_tenant(
          base_config,
          tenant: tenant_name
        )

        expect(result[:db_config].configuration_hash).to eq(base_config_hash.symbolize_keys)
      end
    end

    context 'with unknown strategy' do
      before do
        allow(Apartment.config).to receive(:tenant_strategy).and_return(nil)
      end

      it 'returns default configuration' do
        result = described_class.resolve_for_tenant(
          base_config,
          tenant: tenant_name,
          role: role,
          shard: shard
        )

        expect(result[:db_config]).to eq(Apartment.connection_class.configurations.resolve(base_config))
        expect(result[:role]).to eq(role)
        expect(result[:shard]).to eq(shard)
      end
    end

    context 'with default parameters' do
      it 'uses current role and shard defaults' do
        result = described_class.resolve_for_tenant(base_config, tenant: tenant_name)

        expect(result[:role]).to eq(ActiveRecord::Base.current_role)
        expect(result[:shard]).to eq(ActiveRecord::Base.current_shard)
      end
    end
  end

  describe 'HashConfig integration' do
    let(:env_name) { 'test' }
    let(:name) { 'primary' }
    let(:config_hash) { { adapter: 'postgresql', database: 'test_db' } }
    let(:tenant) { 'test_tenant' }

    context 'when creating HashConfig with tenant' do
      it 'preserves tenant information' do
        hash_config = Apartment::DatabaseConfigurations::HashConfig.new(
          env_name, name, config_hash, tenant
        )

        expect(hash_config.env_name).to eq(env_name)
        expect(hash_config.name).to eq(name)
        expect(hash_config.configuration_hash).to eq(config_hash)
      end
    end

    context 'when creating HashConfig without tenant' do
      it 'works with standard Rails parameters' do
        hash_config = Apartment::DatabaseConfigurations::HashConfig.new(
          env_name, name, config_hash
        )

        expect(hash_config.env_name).to eq(env_name)
        expect(hash_config.name).to eq(name)
        expect(hash_config.configuration_hash).to eq(config_hash)
      end
    end
  end

  describe 'integration with tenant configurations' do
    it 'resolves tenant configurations correctly' do
      tenant_config = Apartment.tenant_configs['tenant1']
      expect(tenant_config).to be_present

      result = described_class.resolve_for_tenant(:test, tenant: 'tenant1')
      expect(result[:db_config].configuration_hash[:schema_search_path]).to eq(tenant_config)
    end

    it 'handles missing tenant configurations' do
      result = described_class.resolve_for_tenant(:test, tenant: 'nonexistent_tenant')

      expect(result[:db_config]).to be_present
      expect(result[:role]).to eq(ActiveRecord::Base.current_role)
      expect(result[:shard]).to eq(ActiveRecord::Base.current_shard)
    end
  end
end