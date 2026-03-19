# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Apartment::Config do
  subject(:config) { described_class.new }

  describe 'defaults' do
    it { expect(config.tenant_strategy).to be_nil }
    it { expect(config.tenants_provider).to be_nil }
    it { expect(config.default_tenant).to be_nil }
    it { expect(config.excluded_models).to eq([]) }
    it { expect(config.persistent_schemas).to eq([]) }
    it { expect(config.tenant_pool_size).to eq(5) }
    it { expect(config.pool_idle_timeout).to eq(300) }
    it { expect(config.max_total_connections).to be_nil }
    it { expect(config.seed_after_create).to eq(false) }
    it { expect(config.seed_data_file).to be_nil }
    it { expect(config.parallel_migration_threads).to eq(0) }
    it { expect(config.parallel_strategy).to eq(:auto) }
    it { expect(config.environmentify_strategy).to be_nil }
    it { expect(config.elevator).to be_nil }
    it { expect(config.elevator_options).to eq({}) }
    it { expect(config.tenant_not_found_handler).to be_nil }
    it { expect(config.active_record_log).to eq(false) }
    it { expect(config.postgres_config).to be_nil }
    it { expect(config.mysql_config).to be_nil }
  end

  describe '#tenant_strategy=' do
    it 'accepts valid strategies' do
      %i[schema database_name shard database_config].each do |strategy|
        expect { config.tenant_strategy = strategy }.not_to raise_error
      end
    end

    it 'rejects invalid strategies' do
      expect { config.tenant_strategy = :invalid }.to raise_error(
        Apartment::ConfigurationError, /Invalid tenant_strategy/
      )
    end
  end

  describe '#parallel_strategy=' do
    it 'rejects invalid strategies' do
      expect { config.parallel_strategy = :bad }.to raise_error(
        Apartment::ConfigurationError, /Invalid parallel_strategy/
      )
    end
  end

  describe '#environmentify_strategy=' do
    it 'accepts nil, :prepend, :append' do
      [nil, :prepend, :append].each do |val|
        expect { config.environmentify_strategy = val }.not_to raise_error
      end
    end

    it 'accepts a callable' do
      expect { config.environmentify_strategy = ->(t) { "test_#{t}" } }.not_to raise_error
    end

    it 'rejects invalid values' do
      expect { config.environmentify_strategy = :bad }.to raise_error(
        Apartment::ConfigurationError, /Invalid environmentify_strategy/
      )
    end
  end

  describe '#configure_postgres' do
    it 'creates a PostgreSQLConfig' do
      pg = config.configure_postgres do |pg|
        pg.persistent_schemas = ['shared']
        pg.enforce_search_path_reset = true
      end

      expect(pg).to be_a(Apartment::Configs::PostgreSQLConfig)
      expect(pg.persistent_schemas).to eq(['shared'])
      expect(pg.enforce_search_path_reset).to eq(true)
      expect(config.postgres_config).to eq(pg)
    end
  end

  describe '#configure_mysql' do
    it 'creates a MySQLConfig' do
      my = config.configure_mysql
      expect(my).to be_a(Apartment::Configs::MySQLConfig)
      expect(config.mysql_config).to eq(my)
    end
  end

  describe '#validate!' do
    it 'raises when tenant_strategy is missing' do
      expect { config.validate! }.to raise_error(
        Apartment::ConfigurationError, /tenant_strategy is required/
      )
    end

    it 'raises when tenants_provider is not callable' do
      config.tenant_strategy = :schema
      config.tenants_provider = 'not_callable'
      expect { config.validate! }.to raise_error(
        Apartment::ConfigurationError, /tenants_provider must be a callable/
      )
    end

    it 'raises when both postgres and mysql are configured' do
      config.tenant_strategy = :schema
      config.tenants_provider = -> { [] }
      config.configure_postgres
      config.configure_mysql
      expect { config.validate! }.to raise_error(
        Apartment::ConfigurationError, /Cannot configure both/
      )
    end

    it 'raises when tenants_provider is missing' do
      config.tenant_strategy = :schema
      expect { config.validate! }.to raise_error(
        Apartment::ConfigurationError, /tenants_provider/
      )
    end

    it 'raises when tenant_pool_size is not a positive integer' do
      config.tenant_strategy = :schema
      config.tenants_provider = -> { [] }
      config.tenant_pool_size = 0
      expect { config.validate! }.to raise_error(Apartment::ConfigurationError, /tenant_pool_size/)
    end

    it 'raises when pool_idle_timeout is not a positive number' do
      config.tenant_strategy = :schema
      config.tenants_provider = -> { [] }
      config.pool_idle_timeout = -1
      expect { config.validate! }.to raise_error(Apartment::ConfigurationError, /pool_idle_timeout/)
    end

    it 'raises when max_total_connections is invalid' do
      config.tenant_strategy = :schema
      config.tenants_provider = -> { [] }
      config.max_total_connections = 0
      expect { config.validate! }.to raise_error(Apartment::ConfigurationError, /max_total_connections/)
    end

    it 'passes with valid minimal configuration' do
      config.tenant_strategy = :schema
      config.tenants_provider = -> { [] }
      expect { config.validate! }.not_to raise_error
    end
  end
end

RSpec.describe 'Apartment.configure' do
  it 'yields a Config instance and stores it' do
    Apartment.configure do |config|
      config.tenant_strategy = :schema
      config.tenants_provider = -> { [] }
      config.default_tenant = 'public'
    end

    expect(Apartment.config).to be_a(Apartment::Config)
    expect(Apartment.config.tenant_strategy).to eq(:schema)
    expect(Apartment.config.default_tenant).to eq('public')
  end

  it 'validates the configuration' do
    expect {
      Apartment.configure { |c| } # no strategy set
    }.to raise_error(Apartment::ConfigurationError)
  end

  it 'raises without a block' do
    expect { Apartment.configure }.to raise_error(Apartment::ConfigurationError, /requires a block/)
  end
end

RSpec.describe 'Apartment.clear_config' do
  it 'resets config and pool_manager to nil' do
    Apartment.configure { |c| c.tenant_strategy = :schema; c.tenants_provider = -> { [] } }
    Apartment.clear_config

    expect(Apartment.config).to be_nil
    expect(Apartment.pool_manager).to be_nil
  end
end
