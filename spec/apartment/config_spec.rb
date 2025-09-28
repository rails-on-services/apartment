# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apartment::Config do
  let(:config) { described_class.new }

  describe 'initialization' do
    it 'sets default values' do
      expect(config.tenants_provider).to be_nil
      expect(config.default_tenant).to be_nil
      expect(config.active_record_log).to be true
      expect(config.connection_class).to eq(ActiveRecord::Base)
      expect(config.postgres_config).to be_nil
      expect(config.mysql_config).to be_nil
    end
  end

  describe 'tenant_strategy' do
    it 'accepts valid strategies' do
      expect { config.tenant_strategy = :schema }.not_to raise_error
      expect { config.tenant_strategy = :shard }.not_to raise_error
      expect { config.tenant_strategy = :database_name }.not_to raise_error
      expect { config.tenant_strategy = :database_config }.not_to raise_error
    end

    it 'rejects invalid strategies' do
      expect { config.tenant_strategy = :invalid }.to raise_error(
        Apartment::ArgumentError,
        /Option invalid not valid for `tenant_strategy`/
      )
    end

    it 'stores the strategy' do
      config.tenant_strategy = :schema
      expect(config.tenant_strategy).to eq(:schema)
    end
  end

  describe 'environmentify_strategy' do
    it 'accepts valid strategies' do
      expect { config.environmentify_strategy = nil }.not_to raise_error
      expect { config.environmentify_strategy = :prepend }.not_to raise_error
      expect { config.environmentify_strategy = :append }.not_to raise_error
    end

    it 'accepts callable objects' do
      callable = ->(tenant) { "#{Rails.env}_#{tenant}" }
      expect { config.environmentify_strategy = callable }.not_to raise_error
      expect(config.environmentify_strategy).to eq(callable)
    end

    it 'rejects invalid strategies' do
      expect { config.environmentify_strategy = :invalid }.to raise_error(
        Apartment::ArgumentError,
        /Option invalid not valid for `environmentify_strategy`/
      )
    end
  end

  describe 'connection_class=' do
    it 'accepts ActiveRecord::Base' do
      expect { config.connection_class = ActiveRecord::Base }.not_to raise_error
      expect(config.connection_class).to eq(ActiveRecord::Base)
    end

    it 'accepts subclasses of ActiveRecord::Base' do
      custom_class = Class.new(ActiveRecord::Base)
      expect { config.connection_class = custom_class }.not_to raise_error
      expect(config.connection_class).to eq(custom_class)
    end

    it 'rejects non-ActiveRecord classes' do
      expect { config.connection_class = String }.to raise_error(
        Apartment::ConfigurationError,
        /Connection class must be ActiveRecord::Base or a subclass/
      )
    end

    it 'sets up custom connection handler' do
      custom_class = Class.new(ActiveRecord::Base)
      config.connection_class = custom_class

      expect(custom_class.default_connection_handler).to be_a(
        Apartment::ConnectionAdapters::ConnectionHandler
      )
    end
  end

  describe 'database-specific configuration' do
    describe 'configure_postgres' do
      it 'creates PostgreSQL config' do
        config.configure_postgres do |pg_config|
          expect(pg_config).to be_a(Apartment::Configs::PostgreSQLConfig)
        end

        expect(config.postgres_config).to be_a(Apartment::Configs::PostgreSQLConfig)
      end

      it 'yields the config for customization' do
        config.configure_postgres do |pg_config|
          pg_config.instance_variable_set(:@test_value, 'configured')
        end

        expect(config.postgres_config.instance_variable_get(:@test_value)).to eq('configured')
      end
    end

    describe 'configure_mysql' do
      it 'creates MySQL config' do
        config.configure_mysql do |mysql_config|
          expect(mysql_config).to be_a(Apartment::Configs::MySQLConfig)
        end

        expect(config.mysql_config).to be_a(Apartment::Configs::MySQLConfig)
      end
    end
  end

  describe 'validation' do
    context 'with valid configuration' do
      before do
        config.tenants_provider = -> { %w[tenant1 tenant2] }
      end

      it 'passes validation' do
        expect { config.validate! }.not_to raise_error
      end
    end

    context 'without tenants_provider' do
      it 'fails validation' do
        expect { config.validate! }.to raise_error(
          Apartment::ConfigurationError,
          /tenants_provider must be a callable/
        )
      end
    end

    context 'with non-callable tenants_provider' do
      before do
        config.tenants_provider = %w[tenant1 tenant2]
      end

      it 'fails validation' do
        expect { config.validate! }.to raise_error(
          Apartment::ConfigurationError,
          /tenants_provider must be a callable/
        )
      end
    end

    context 'with both postgres and mysql configs' do
      before do
        config.tenants_provider = -> { %w[tenant1] }
        config.configure_postgres { |_| }
        config.configure_mysql { |_| }
      end

      it 'fails validation' do
        expect { config.validate! }.to raise_error(
          Apartment::ConfigurationError,
          /Cannot configure both Postgres and MySQL/
        )
      end
    end
  end

  describe 'apply!' do
    it 'applies postgres configuration' do
      config.configure_postgres { |_| }
      postgres_config = config.postgres_config

      expect(postgres_config).to receive(:apply!)
      config.apply!
    end

    it 'applies mysql configuration' do
      config.configure_mysql { |_| }
      mysql_config = config.mysql_config

      expect(mysql_config).to receive(:apply!)
      config.apply!
    end

    it 'handles missing configurations gracefully' do
      expect { config.apply! }.not_to raise_error
    end
  end

  describe 'delegation' do
    before do
      config.default_tenant = 'test_tenant'
      config.connection_class = ActiveRecord::Base
    end

    it 'delegates default_tenant' do
      expect(config.default_tenant).to eq('test_tenant')
    end

    it 'delegates connection_class' do
      expect(config.connection_class).to eq(ActiveRecord::Base)
    end

    it 'delegates connection_db_config' do
      expect(config).to respond_to(:connection_db_config)
    end
  end
end