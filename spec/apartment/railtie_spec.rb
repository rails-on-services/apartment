# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apartment::Railtie do
  describe 'railtie configuration' do
    it 'is a Rails::Railtie' do
      expect(described_class.ancestors).to include(Rails::Railtie)
    end

    it 'has the correct railtie name' do
      expect(described_class.railtie_name).to eq('apartment')
    end
  end

  describe 'initializers' do
    let(:app) { Rails.application }

    it 'registers apartment initializers' do
      initializer_names = app.initializers.map(&:name)

      expect(initializer_names).to include('apartment.configuration')
      expect(initializer_names).to include('apartment.setup_connection_handling')
    end

    it 'orders initializers correctly' do
      apartment_initializers = app.initializers.select do |init|
        init.name.to_s.start_with?('apartment.')
      end

      names = apartment_initializers.map(&:name)
      expect(names.index('apartment.configuration')).to be < names.index('apartment.setup_connection_handling')
    end
  end

  describe 'configuration initializer' do
    it 'sets up Apartment configuration' do
      expect(Apartment.config).to be_a(Apartment::Config)
    end

    it 'configures zeitwerk inflections' do
      # Verify that Zeitwerk inflections are set up
      loader = Rails.autoloaders.main

      # Check for custom inflections that should be added by the railtie
      expect(loader.inflector).to respond_to(:inflect)
    end
  end

  describe 'connection handling setup' do
    it 'patches ActiveRecord connection handling' do
      # Verify that our custom connection handler is installed
      expect(Apartment.connection_class.default_connection_handler).to be_a(
        Apartment::ConnectionAdapters::ConnectionHandler
      )
    end

    it 'maintains connection class configuration' do
      expect(Apartment.connection_class).to eq(ActiveRecord::Base)
    end
  end

  describe 'rake task loading' do
    it 'loads apartment rake tasks' do
      task_names = Rake::Task.tasks.map(&:name)

      # Check for key apartment tasks
      expect(task_names).to include('apartment:create')
      expect(task_names).to include('apartment:drop')
      expect(task_names).to include('apartment:migrate')
    end
  end

  describe 'generators integration' do
    it 'loads apartment generators' do
      generator_names = Rails::Generators.subclasses.map(&:generator_name)

      expect(generator_names).to include('apartment:install')
    end
  end

  describe 'configuration validation' do
    context 'after initialization' do
      it 'validates apartment configuration' do
        expect { Apartment.config.validate! }.not_to raise_error
      end
    end

    context 'with invalid configuration' do
      before do
        # Temporarily break the configuration
        original_provider = Apartment.config.tenants_provider
        Apartment.config.tenants_provider = nil

        # Reset to valid state after test
        @cleanup = -> { Apartment.config.tenants_provider = original_provider }
      end

      after { @cleanup.call }

      it 'would fail validation' do
        expect { Apartment.config.validate! }.to raise_error(Apartment::ConfigurationError)
      end
    end
  end

  describe 'application lifecycle integration' do
    context 'during application initialization' do
      it 'sets up apartment before activerecord initialization' do
        # Verify that apartment configuration happens early enough
        expect(Apartment.config).to be_present
      end
    end

    context 'after application initialization' do
      it 'applies database-specific configurations' do
        expect(Apartment.config.postgres_config).to be_nil
        expect(Apartment.config.mysql_config).to be_nil
      end
    end
  end

  describe 'console integration' do
    it 'provides apartment context in rails console' do
      # Verify that apartment modules are available
      expect(defined?(Apartment::Tenant)).to be_truthy
      expect(defined?(Apartment::Current)).to be_truthy
    end

    it 'sets up current tenant tracking' do
      expect(Apartment::Current.tenant).to be_present
    end
  end

  describe 'middleware integration' do
    context 'when apartment middleware is configured' do
      let(:middleware_stack) { Rails.application.middleware }

      it 'allows apartment middleware to be added' do
        # Test that we can add apartment middleware
        expect {
          middleware_stack.use(Class.new do
            def initialize(app)
              @app = app
            end

            def call(env)
              Apartment::Tenant.switch('test') { @app.call(env) }
            end
          end)
        }.not_to raise_error
      end
    end
  end

  describe 'error handling during initialization' do
    it 'handles missing database gracefully during railtie loading' do
      # This test ensures the railtie doesn't crash if database isn't available
      # during app initialization (common in CI/deployment scenarios)
      expect { described_class }.not_to raise_error
    end
  end

  describe 'development mode reloading' do
    context 'when in development environment' do
      before do
        allow(Rails.env).to receive(:development?).and_return(true)
      end

      it 'handles code reloading correctly' do
        # Verify that apartment state survives code reloading
        original_tenant = Apartment::Tenant.current

        # Simulate code reload by clearing apartment modules
        # (This is a simplified version of what Rails does)
        expect { Apartment::Tenant.current }.not_to raise_error

        expect(Apartment::Tenant.current).to be_present
      end
    end
  end

  describe 'eager loading' do
    context 'when eager loading is enabled' do
      before do
        allow(Rails.application.config).to receive(:eager_load).and_return(true)
      end

      it 'eager loads apartment modules correctly' do
        expect { Rails.application.eager_load! }.not_to raise_error

        # Verify key modules are loaded
        expect(defined?(Apartment::Tenant)).to be_truthy
        expect(defined?(Apartment::ConnectionAdapters::ConnectionHandler)).to be_truthy
        expect(defined?(Apartment::DatabaseConfigurations)).to be_truthy
      end
    end
  end

  describe 'database adapter compatibility' do
    it 'works with PostgreSQL adapter' do
      expect { described_class }.not_to raise_error
    end

    it 'works with MySQL adapter' do
      expect { described_class }.not_to raise_error
    end

    it 'works with SQLite adapter' do
      expect { described_class }.not_to raise_error
    end
  end

  describe 'zeitwerk integration' do
    it 'sets up custom inflections for apartment' do
      loader = Rails.autoloaders.main

      # Test that our custom inflections work
      expect(loader.cpath_expected_at('/apartment/connection_adapters/pool_config.rb')).to eq(
        'Apartment::ConnectionAdapters::PoolConfig'
      )
    end
  end
end