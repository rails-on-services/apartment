# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'PostgreSQL Stress Tests', :postgresql do
  before(:all) do
    Apartment.configure do |config|
      config.default_tenant = 'public'
      config.tenant_strategy = :schema
      config.tenants_provider = -> { (1..50).map { |i| "stress_tenant_#{i}" } }
    end
  end

  before do
    Apartment::Tenant.reset
  end

  describe 'High volume tenant switching' do
    it 'handles rapid tenant switches without memory leaks' do
      # Track memory usage (simplified - would need proper profiling tools for real tests)
      initial_pool_count = ActiveRecord::Base.connection_handler.instance_variable_get(:@connection_name_to_pool_manager).size

      # Perform many rapid switches
      100.times do |i|
        tenant_name = "stress_tenant_#{(i % 50) + 1}"
        Apartment::Tenant.switch!(tenant_name)

        # Verify we're in the right tenant
        expect(Apartment::Tenant.current).to eq(tenant_name)

        # Verify connection pool exists
        expect(ActiveRecord::Base.connection_pool).to be_present
      end

      # Check that we haven't created excessive pool managers
      final_pool_count = ActiveRecord::Base.connection_handler.instance_variable_get(:@connection_name_to_pool_manager).size

      # Should be roughly the number of unique tenants we switched to (50) plus some overhead
      expect(final_pool_count).to be <= initial_pool_count + 55
    end

    it 'maintains connection pool integrity under load' do
      pools = {}

      # Switch to multiple tenants and collect their pools
      (1..20).each do |i|
        tenant_name = "stress_tenant_#{i}"
        Apartment::Tenant.switch!(tenant_name)
        pools[tenant_name] = ActiveRecord::Base.connection_pool
      end

      # Verify all pools are different
      pool_objects = pools.values.map(&:object_id)
      expect(pool_objects.uniq.length).to eq(20)

      # Switch back to each tenant and verify we get the same pool
      (1..20).each do |i|
        tenant_name = "stress_tenant_#{i}"
        Apartment::Tenant.switch!(tenant_name)
        current_pool = ActiveRecord::Base.connection_pool

        expect(current_pool.object_id).to eq(pools[tenant_name].object_id)
      end
    end
  end

  describe 'Concurrent tenant operations' do
    it 'handles concurrent tenant switches correctly' do
      results = Concurrent::Hash.new
      errors = Concurrent::Array.new

      # Create multiple threads that switch tenants concurrently
      threads = 20.times.map do |thread_id|
        Thread.new do
          begin
            tenant_name = "stress_tenant_#{(thread_id % 10) + 1}"

            # Multiple switches per thread to increase contention
            10.times do
              Apartment::Tenant.switch(tenant_name) do
                sleep 0.001 # Small delay to allow context switching
                results["#{thread_id}_#{tenant_name}"] = Apartment::Tenant.current
              end
            end
          rescue => e
            errors << "Thread #{thread_id}: #{e.message}"
          end
        end
      end

      # Wait for all threads to complete
      threads.each(&:join)

      # Should have no errors
      expect(errors).to be_empty

      # Each thread should have recorded correct tenant names
      results.each do |key, recorded_tenant|
        # key format: "thread_id_stress_tenant_N"
        expected_tenant = key.split('_', 2).last # Gets "stress_tenant_N"
        expect(recorded_tenant).to eq(expected_tenant)
      end
    end

    it 'handles mixed block and manual switching concurrently' do
      results = Concurrent::Array.new
      barrier = Concurrent::CountDownLatch.new(10)

      threads = 10.times.map do |i|
        Thread.new do
          tenant_name = "stress_tenant_#{i + 1}"

          if i.even?
            # Use block-scoped switching
            Apartment::Tenant.switch(tenant_name) do
              barrier.count_down
              barrier.wait(2)
              sleep 0.01
              results << { thread: i, tenant: Apartment::Tenant.current, type: :block }
            end
          else
            # Use manual switching
            Apartment::Tenant.switch!(tenant_name)
            barrier.count_down
            barrier.wait(2)
            sleep 0.01
            results << { thread: i, tenant: Apartment::Tenant.current, type: :manual }
            Apartment::Tenant.reset
          end
        end
      end

      threads.each(&:join)

      # Verify each thread recorded the correct tenant
      results.each do |result|
        expected_tenant = "stress_tenant_#{result[:thread] + 1}"
        expect(result[:tenant]).to eq(expected_tenant)
      end
    end
  end

  describe 'Connection specification name consistency' do
    it 'maintains correct names under rapid switching' do
      tenant_specs = {}

      # Rapidly switch and collect connection specification names
      50.times do |i|
        tenant_name = "stress_tenant_#{i + 1}"
        Apartment::Tenant.switch!(tenant_name)

        spec_name = ActiveRecord::Base.connection_specification_name
        tenant_specs[tenant_name] = spec_name

        expect(spec_name).to eq("ActiveRecord::Base[#{tenant_name}]")
      end

      # Switch back to each tenant and verify specification names are consistent
      tenant_specs.each do |tenant_name, original_spec|
        Apartment::Tenant.switch!(tenant_name)
        current_spec = ActiveRecord::Base.connection_specification_name

        expect(current_spec).to eq(original_spec)
      end
    end
  end

  describe 'Exception handling under stress' do
    it 'properly resets tenant context when exceptions occur in concurrent scenarios' do
      original_tenant = Apartment::Tenant.current
      results = Concurrent::Array.new

      threads = 20.times.map do |i|
        Thread.new do
          begin
            tenant_name = "stress_tenant_#{i + 1}"

            # Some threads will raise exceptions
            Apartment::Tenant.switch(tenant_name) do
              if i.odd?
                raise StandardError, "Intentional error in thread #{i}"
              end
              sleep 0.01
            end

            # Record final tenant state
            results << { thread: i, final_tenant: Apartment::Tenant.current }
          rescue StandardError
            # Exception should be caught, tenant should be reset
            results << { thread: i, final_tenant: Apartment::Tenant.current }
          end
        end
      end

      threads.each(&:join)

      # All threads should end up back at the original tenant
      results.each do |result|
        expect(result[:final_tenant]).to eq(original_tenant)
      end
    end
  end

  describe 'Database strategy resolution under load' do
    it 'correctly resolves tenant configurations for many tenants' do
      resolved_configs = {}

      # Resolve configurations for all stress tenants
      (1..50).each do |i|
        tenant_name = "stress_tenant_#{i}"

        resolved = Apartment::DatabaseConfigurations.resolve_for_tenant(
          :test,
          tenant: tenant_name
        )

        resolved_configs[tenant_name] = resolved

        # Should have correct schema search path
        expect(resolved[:db_config].configuration_hash).to have_key(:schema_search_path)
        expect(resolved[:db_config].configuration_hash[:schema_search_path]).to eq(%("#{tenant_name}"))
      end

      # Verify all configurations are unique objects but have correct structure
      expect(resolved_configs.values.length).to eq(50)

      resolved_configs.each do |tenant_name, config|
        expect(config[:role]).to eq(:writing)
        expect(config[:shard]).to eq(:default)
        expect(config[:db_config].configuration_hash[:schema_search_path]).to eq(%("#{tenant_name}"))
      end
    end
  end
end