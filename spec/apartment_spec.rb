# frozen_string_literal: true

require 'spec_helper'

RSpec.describe(Apartment) do
  it 'is valid' do
    expect(described_class).to(be_a(Module))
  end

  describe 'Configuration' do
    it 'allows setting and getting configuration options' do
      described_class.use_schemas = true
      described_class.use_sql = false

      expect(described_class.use_schemas).to(be(true))
      expect(described_class.use_sql).to(be(false))
    end

    it 'resets configuration options to defaults' do
      described_class.use_schemas = true
      described_class.reset

      expect(described_class.use_schemas).to(be_falsey)
    end
  end

  describe '.configure' do
    it 'yields itself for configuration' do
      described_class.configure do |config|
        config.use_schemas = true
      end

      expect(described_class.use_schemas).to(be(true))
    end
  end

  describe '.tenant_names' do
    context 'when no value is explicitly set' do
      it 'uses the default value from tenants_config' do
        allow(described_class).to(receive(:tenants_config).and_return({ tenant1: {}, tenant2: {} }))

        expect(described_class.tenant_names).to(contain_exactly('tenant1', 'tenant2'))
      end
    end

    context 'when a value is explicitly set' do
      it 'returns tenant names as strings' do
        described_class.tenant_names = %w[tenant1 tenant2]

        expect(described_class.tenant_names).to(contain_exactly('tenant1', 'tenant2'))
      end

      it 'calls a proc if tenant_names is callable' do
        described_class.tenant_names = -> { %w[tenant1 tenant2] }

        expect(described_class.tenant_names).to(be)
      end
    end
  end

  describe '.tenants_config' do
    it 'normalizes tenant names into a hash with configurations' do
      described_class.tenant_names = %w[tenant1 tenant2]

      allow(described_class).to(receive(:connection_config).and_return({ key: 'value' }))

      expect(described_class.tenants_config).to(match(
                                                  'tenant1' => { key: 'value' },
                                                  'tenant2' => { key: 'value' }
                                                ))
    end
  end

  describe '.db_config_for' do
    it 'returns configuration for a specific tenant' do
      described_class.tenant_names = { tenant1: { key: 'value' } }

      expect(described_class.db_config_for('tenant1')).to(match({ key: 'value' }))
    end

    it 'falls back to connection config if no specific configuration is found' do
      allow(described_class).to(receive(:connection_config).and_return({ key: 'default_value' }))

      expect(described_class.db_config_for('unknown_tenant')).to(match({ key: 'default_value' }))
    end
  end

  describe 'attribute defaults' do
    it 'provides default values for excluded models and persistent schemas' do
      expect(described_class.excluded_models).to(eq([]))
      expect(described_class.persistent_schemas).to(eq([]))
    end

    it 'provides default paths for schema and seed files' do
      expect(described_class.database_schema_file).to(eq(Rails.root.join('db/schema.rb')))
      expect(described_class.seed_data_file).to(eq(Rails.root.join('db/seeds.rb')))
    end

    it 'sets default values for skip_create_schema and enforce_search_path_reset' do
      expect(described_class.skip_create_schema).to(be(true))
      expect(described_class.enforce_search_path_reset).to(be(false))
    end
  end

  describe '.reset' do
    it 'resets all configurations to their defaults' do
      described_class.use_schemas = true
      described_class.excluded_models = ['Model']

      described_class.reset

      expect(described_class.use_schemas).to(be(false))
      expect(described_class.excluded_models).to(eq([]))
    end
  end

  describe '.validate_strategy!' do
    it 'raises an error for invalid strategies' do
      expect do
        described_class.send(:validate_strategy!, :invalid, %i[valid1 valid2], 'config.test_strategy')
      end.to(raise_error(ArgumentError,
                         'Option invalid not valid for `config.test_strategy`. Use one of valid1, valid2'))
    end
  end

  describe '.environmentify=' do
    it 'sets the value when given a valid strategy' do
      described_class.environmentify = :prepend

      expect(described_class.config.environmentify).to(eq(:prepend))
    end

    it 'accepts a callable object' do
      callable = ->(tenant) { "custom_#{tenant}" }
      described_class.environmentify = callable

      expect(described_class.config.environmentify).to(eq(callable))
    end

    it 'raises an error for invalid strategies' do
      expect do
        described_class.environmentify = :invalid_strategy
      end.to(raise_error(ArgumentError,
                         'Option invalid_strategy not valid for `config.environmentify`. Use one of prepend, append'))
    end
  end

  describe '.db_migrate_tenant_missing_strategy=' do
    it 'sets the value when given a valid strategy' do
      described_class.db_migrate_tenant_missing_strategy = :raise_exception

      expect(described_class.config.db_migrate_tenant_missing_strategy).to(eq(:raise_exception))
    end

    it 'raises an error for invalid strategies' do
      expect do
        described_class.db_migrate_tenant_missing_strategy = :invalid_strategy
      end.to(raise_error(ArgumentError,
                         'Option invalid_strategy not valid for `config.db_migrate_tenant_missing_strategy`. Use one of rescue_exception, raise_exception, create_tenant'))
    end
  end

  describe 'Custom Errors' do
    it 'defines ApartmentError' do
      expect(Apartment::ApartmentError).to(be < StandardError)
    end

    it 'defines ArgumentError' do
      expect(Apartment::ArgumentError).to(be < ArgumentError)
    end

    it 'defines FileNotFound' do
      expect(Apartment::FileNotFound).to(be < Apartment::ApartmentError)
    end

    it 'defines AdapterNotFound' do
      expect(Apartment::AdapterNotFound).to(be < Apartment::ApartmentError)
    end

    it 'defines TenantNotFound' do
      expect(Apartment::TenantNotFound).to(be < Apartment::ApartmentError)
    end

    it 'defines TenantAlreadyExists' do
      expect(Apartment::TenantAlreadyExists).to(be < Apartment::ApartmentError)
    end
  end
end
