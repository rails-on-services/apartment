# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Apartment Error Handling' do
  before(:all) do
    Apartment.configure do |config|
      config.default_tenant = 'public'
      config.tenant_strategy = :schema
      config.tenants_provider = -> { %w[tenant1 tenant2 valid_tenant] }
    end
  end

  before { Apartment::Tenant.reset }

  describe 'invalid tenant handling' do
    context 'when switching to non-existent tenant' do
      it 'handles gracefully with schema strategy' do
        allow(Apartment.config).to receive(:tenant_strategy).and_return(:schema)

        expect {
          Apartment::Tenant.switch!('nonexistent_tenant')
        }.not_to raise_error

        expect(Apartment::Tenant.current).to eq('nonexistent_tenant')
      end

      it 'handles gracefully with database_name strategy' do
        allow(Apartment.config).to receive(:tenant_strategy).and_return(:database_name)

        expect {
          Apartment::Tenant.switch!('nonexistent_tenant')
        }.not_to raise_error

        expect(Apartment::Tenant.current).to eq('nonexistent_tenant')
      end
    end

    context 'when tenant configuration is missing' do
      it 'falls back to tenant name as configuration' do
        allow(Apartment.tenant_configs).to receive(:[]).with('missing_config_tenant').and_return(nil)

        expect {
          Apartment::Tenant.switch!('missing_config_tenant')
        }.not_to raise_error

        expect(Apartment::Tenant.current).to eq('missing_config_tenant')
      end
    end
  end

  describe 'database connection errors' do
    context 'when database connection fails during switch' do
      let(:failing_connection) { double('connection') }

      before do
        allow(failing_connection).to receive(:execute).and_raise(
          ActiveRecord::ConnectionNotEstablished.new('Connection failed')
        )
      end

      it 'propagates connection errors appropriately' do
        # Mock the connection to fail
        allow_any_instance_of(Apartment::ConnectionAdapters::ConnectionHandler)
          .to receive(:retrieve_connection_pool)
          .and_raise(ActiveRecord::ConnectionNotEstablished.new('Connection failed'))

        expect {
          Apartment::Tenant.switch!('valid_tenant')
          ActiveRecord::Base.connection
        }.to raise_error(ActiveRecord::ConnectionNotEstablished)
      end
    end

    context 'when database does not exist' do
      it 'handles database not found errors' do
        allow_any_instance_of(ActiveRecord::ConnectionAdapters::ConnectionPool)
          .to receive(:connection)
          .and_raise(ActiveRecord::NoDatabaseError.new('Database does not exist'))

        expect {
          Apartment::Tenant.switch!('valid_tenant')
          ActiveRecord::Base.connection
        }.to raise_error(ActiveRecord::NoDatabaseError)
      end
    end
  end

  describe 'configuration errors' do
    context 'with invalid tenant strategy' do
      it 'raises appropriate error during configuration' do
        expect {
          Apartment.configure do |config|
            config.tenant_strategy = :invalid_strategy
          end
        }.to raise_error(Apartment::ArgumentError, /Option invalid_strategy not valid for `tenant_strategy`/)
      end
    end

    context 'with invalid environmentify strategy' do
      it 'raises appropriate error during configuration' do
        expect {
          Apartment.configure do |config|
            config.environmentify_strategy = :invalid_environmentify
          end
        }.to raise_error(Apartment::ArgumentError, /Option invalid_environmentify not valid for `environmentify_strategy`/)
      end
    end

    context 'with missing tenants_provider' do
      it 'raises configuration error during validation' do
        config = Apartment::Config.new
        # tenants_provider defaults to nil

        expect {
          config.validate!
        }.to raise_error(Apartment::ConfigurationError, /tenants_provider must be a callable/)
      end
    end

    context 'with non-callable tenants_provider' do
      it 'raises configuration error during validation' do
        config = Apartment::Config.new
        config.tenants_provider = %w[tenant1 tenant2] # Array instead of callable

        expect {
          config.validate!
        }.to raise_error(Apartment::ConfigurationError, /tenants_provider must be a callable/)
      end
    end

    context 'with both postgres and mysql configs' do
      it 'raises configuration error during validation' do
        config = Apartment::Config.new
        config.tenants_provider = -> { %w[tenant1] }
        config.configure_postgres { |_| }
        config.configure_mysql { |_| }

        expect {
          config.validate!
        }.to raise_error(Apartment::ConfigurationError, /Cannot configure both Postgres and MySQL/)
      end
    end

    context 'with invalid connection class' do
      it 'raises configuration error' do
        config = Apartment::Config.new

        expect {
          config.connection_class = String
        }.to raise_error(Apartment::ConfigurationError, /Connection class must be ActiveRecord::Base or a subclass/)
      end
    end
  end

  describe 'block switching error handling' do
    context 'when exception occurs within switch block' do
      it 'restores original tenant on exception' do
        original_tenant = Apartment::Tenant.current

        expect {
          Apartment::Tenant.switch('valid_tenant') do
            expect(Apartment::Tenant.current).to eq('valid_tenant')
            raise StandardError, 'Something went wrong'
          end
        }.to raise_error(StandardError, 'Something went wrong')

        expect(Apartment::Tenant.current).to eq(original_tenant)
      end

      it 'handles nested exceptions properly' do
        original_tenant = Apartment::Tenant.current

        expect {
          Apartment::Tenant.switch('tenant1') do
            Apartment::Tenant.switch('tenant2') do
              expect(Apartment::Tenant.current).to eq('tenant2')
              raise StandardError, 'Inner exception'
            end
          end
        }.to raise_error(StandardError, 'Inner exception')

        expect(Apartment::Tenant.current).to eq(original_tenant)
      end
    end

    context 'when tenant switching fails within block' do
      it 'handles switching errors gracefully' do
        original_tenant = Apartment::Tenant.current

        # Mock a failure during tenant switching
        allow(Apartment::DatabaseConfigurations).to receive(:resolve_for_tenant)
          .and_raise(StandardError.new('Tenant resolution failed'))

        expect {
          Apartment::Tenant.switch('valid_tenant') do
            # This should not be reached
            raise StandardError, 'Should not reach here'
          end
        }.to raise_error(StandardError, 'Tenant resolution failed')

        # Current tenant should be restored even though switch failed
        expect(Apartment::Tenant.current).to eq(original_tenant)
      end
    end
  end

  describe 'thread safety error handling' do
    it 'handles exceptions in concurrent tenant switching' do
      results = Concurrent::Array.new
      errors = Concurrent::Array.new

      threads = 5.times.map do |i|
        Thread.new do
          begin
            Apartment::Tenant.switch("tenant#{i % 2}") do
              if i == 2
                raise StandardError, "Thread #{i} error"
              end
              results << "tenant#{i % 2}"
            end
          rescue StandardError => e
            errors << e.message
          end
        end
      end

      threads.each(&:join)

      expect(errors.size).to eq(1)
      expect(errors.first).to eq('Thread 2 error')
      expect(results.size).to eq(4) # 4 successful threads
    end

    it 'isolates errors between threads' do
      error_count = Concurrent::AtomicFixnum.new(0)
      success_count = Concurrent::AtomicFixnum.new(0)

      threads = 10.times.map do |i|
        Thread.new do
          begin
            Apartment::Tenant.switch("tenant#{i}") do
              if i.even?
                raise StandardError, "Error in thread #{i}"
              end
              success_count.increment
            end
          rescue StandardError
            error_count.increment
          end
        end
      end

      threads.each(&:join)

      expect(error_count.value).to eq(5) # Even numbered threads
      expect(success_count.value).to eq(5) # Odd numbered threads
    end
  end

  describe 'memory leak prevention on errors' do
    it 'cleans up connection pools after errors' do
      initial_pools = Apartment.connection_class.default_connection_handler
                                .instance_variable_get(:@connection_name_to_pool_manager).size

      100.times do |i|
        begin
          Apartment::Tenant.switch("error_tenant_#{i}") do
            if i % 10 == 0
              raise StandardError, 'Simulated error'
            end
            # Normal operation
          end
        rescue StandardError
          # Ignore errors for this test
        end
      end

      # Connection pools should not grow indefinitely due to errors
      final_pools = Apartment.connection_class.default_connection_handler
                              .instance_variable_get(:@connection_name_to_pool_manager).size

      # Allow some growth but not excessive
      expect(final_pools).to be < (initial_pools + 50)
    end
  end

  describe 'configuration resolution errors' do
    context 'when database configuration resolution fails' do
      it 'handles schema strategy resolution errors' do
        allow(Apartment.config).to receive(:tenant_strategy).and_return(:schema)
        allow(Apartment.tenant_configs).to receive(:[]).and_raise(StandardError.new('Config error'))

        expect {
          Apartment::DatabaseConfigurations.resolve_for_tenant(:test, tenant: 'error_tenant')
        }.to raise_error(StandardError, 'Config error')
      end

      it 'handles database_config strategy resolution errors' do
        allow(Apartment.config).to receive(:tenant_strategy).and_return(:database_config)
        allow(Apartment.tenant_configs).to receive(:[]).and_raise(StandardError.new('Config error'))

        expect {
          Apartment::DatabaseConfigurations.resolve_for_tenant(:test, tenant: 'error_tenant')
        }.to raise_error(StandardError, 'Config error')
      end
    end
  end

  describe 'edge case handling' do
    context 'with nil tenant names' do
      it 'handles nil tenant gracefully' do
        expect {
          Apartment::Tenant.switch!(nil)
        }.not_to raise_error

        expect(Apartment::Tenant.current).to eq('')
      end
    end

    context 'with empty string tenant names' do
      it 'handles empty string tenant gracefully' do
        expect {
          Apartment::Tenant.switch!('')
        }.not_to raise_error

        expect(Apartment::Tenant.current).to eq('')
      end
    end

    context 'with very long tenant names' do
      it 'handles long tenant names' do
        long_tenant = 'a' * 1000

        expect {
          Apartment::Tenant.switch!(long_tenant)
        }.not_to raise_error

        expect(Apartment::Tenant.current).to eq(long_tenant)
      end
    end

    context 'with special characters in tenant names' do
      it 'handles special characters gracefully' do
        special_tenant = 'tenant-with_special.chars@domain'

        expect {
          Apartment::Tenant.switch!(special_tenant)
        }.not_to raise_error

        expect(Apartment::Tenant.current).to eq(special_tenant)
      end
    end
  end

  describe 'recursive switching error handling' do
    it 'handles deeply nested tenant switching' do
      original_tenant = Apartment::Tenant.current

      expect {
        Apartment::Tenant.switch('level1') do
          Apartment::Tenant.switch('level2') do
            Apartment::Tenant.switch('level3') do
              Apartment::Tenant.switch('level4') do
                expect(Apartment::Tenant.current).to eq('level4')
                raise StandardError, 'Deep error'
              end
            end
          end
        end
      }.to raise_error(StandardError, 'Deep error')

      expect(Apartment::Tenant.current).to eq(original_tenant)
    end
  end

  describe 'tenant configuration map error handling' do
    let(:config_map) { Apartment::Tenants::ConfigurationMap.new }

    it 'handles invalid tenant configurations gracefully' do
      expect {
        config_map.add_or_replace(nil)
      }.not_to raise_error
    end

    it 'handles hash configurations without tenant key' do
      invalid_config = { 'database' => 'some_db' }

      expect {
        config_map.add_or_replace(invalid_config)
      }.not_to raise_error
    end

    it 'handles environmentify strategy errors' do
      allow(Apartment.config).to receive(:environmentify_strategy).and_raise(StandardError.new('Strategy error'))

      expect {
        config_map.add_or_replace('test_tenant')
      }.to raise_error(StandardError, 'Strategy error')
    end
  end

  describe 'connection pool error recovery' do
    it 'recovers from temporary connection pool errors' do
      call_count = 0
      allow_any_instance_of(Apartment::ConnectionAdapters::PoolManager)
        .to receive(:get_pool) do |*args|
          call_count += 1
          if call_count == 1
            raise StandardError.new('Temporary pool error')
          else
            # Return a valid pool on retry
            original_method = Apartment::ConnectionAdapters::PoolManager.instance_method(:get_pool)
            original_method.bind(self).call(*args)
          end
        end

      # First call should fail
      expect {
        Apartment::Tenant.switch!('recovery_tenant')
        ActiveRecord::Base.connection
      }.to raise_error(StandardError, 'Temporary pool error')

      # Reset to allow normal operation
      allow_any_instance_of(Apartment::ConnectionAdapters::PoolManager).to receive(:get_pool).and_call_original

      # Second call should succeed
      expect {
        Apartment::Tenant.switch!('recovery_tenant')
        ActiveRecord::Base.connection
      }.not_to raise_error
    end
  end
end