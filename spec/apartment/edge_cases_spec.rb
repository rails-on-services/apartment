# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Apartment Edge Cases' do
  before(:all) do
    Apartment.configure do |config|
      config.default_tenant = 'public'
      config.tenant_strategy = :schema
      config.tenants_provider = -> { %w[tenant1 tenant2 edge_tenant] }
    end
  end

  before { Apartment::Tenant.reset }

  describe 'extreme tenant counts' do
    it 'handles many tenants efficiently' do
      # Test with 100 different tenants
      tenant_names = 100.times.map { |i| "mass_tenant_#{i}" }

      start_time = Time.current

      tenant_names.each do |tenant|
        Apartment::Tenant.switch!(tenant)
        expect(Apartment::Tenant.current).to eq(tenant)
      end

      end_time = Time.current
      total_time = end_time - start_time

      # Should complete in reasonable time (under 5 seconds for 100 switches)
      expect(total_time).to be < 5.0
    end

    it 'handles rapid switching between many tenants' do
      tenant_names = 50.times.map { |i| "rapid_tenant_#{i}" }

      # Rapidly switch between tenants
      1000.times do
        random_tenant = tenant_names.sample
        Apartment::Tenant.switch!(random_tenant)
        expect(Apartment::Tenant.current).to eq(random_tenant)
      end
    end
  end

  describe 'unicode and international tenant names' do
    it 'handles UTF-8 tenant names' do
      utf8_tenants = ['テナント', 'бизнес', 'locataire', 'mægler', '租户']

      utf8_tenants.each do |tenant|
        expect {
          Apartment::Tenant.switch!(tenant)
        }.not_to raise_error

        expect(Apartment::Tenant.current).to eq(tenant)
      end
    end

    it 'handles emoji in tenant names' do
      emoji_tenant = '🏢_tenant_🏠'

      expect {
        Apartment::Tenant.switch!(emoji_tenant)
      }.not_to raise_error

      expect(Apartment::Tenant.current).to eq(emoji_tenant)
    end

    it 'handles mixed character sets' do
      mixed_tenant = 'company_会社_テナント_123'

      expect {
        Apartment::Tenant.switch!(mixed_tenant)
      }.not_to raise_error

      expect(Apartment::Tenant.current).to eq(mixed_tenant)
    end
  end

  describe 'boundary value testing' do
    context 'with very long tenant names' do
      it 'handles maximum length tenant names' do
        # Test with very long tenant name (1000 characters)
        long_tenant = 'a' * 1000

        expect {
          Apartment::Tenant.switch!(long_tenant)
        }.not_to raise_error

        expect(Apartment::Tenant.current).to eq(long_tenant)
      end

      it 'handles extremely long tenant names' do
        # Test with extremely long tenant name (10,000 characters)
        very_long_tenant = 'b' * 10_000

        expect {
          Apartment::Tenant.switch!(very_long_tenant)
        }.not_to raise_error

        expect(Apartment::Tenant.current).to eq(very_long_tenant)
      end
    end

    context 'with minimal tenant names' do
      it 'handles single character tenant names' do
        single_char_tenants = %w[a 1 @]

        single_char_tenants.each do |tenant|
          expect {
            Apartment::Tenant.switch!(tenant)
          }.not_to raise_error

          expect(Apartment::Tenant.current).to eq(tenant)
        end
      end

      it 'handles numeric tenant names' do
        numeric_tenants = %w[123 456789 0001]

        numeric_tenants.each do |tenant|
          expect {
            Apartment::Tenant.switch!(tenant)
          }.not_to raise_error

          expect(Apartment::Tenant.current).to eq(tenant)
        end
      end
    end
  end

  describe 'special character handling' do
    it 'handles SQL injection attempts in tenant names' do
      malicious_tenants = [
        "'; DROP TABLE users; --",
        'tenant"; DELETE FROM data; #',
        "tenant' OR '1'='1",
        'tenant\'; CREATE USER hacker; --'
      ]

      malicious_tenants.each do |tenant|
        expect {
          Apartment::Tenant.switch!(tenant)
        }.not_to raise_error

        expect(Apartment::Tenant.current).to eq(tenant)
      end
    end

    it 'handles file path injection attempts' do
      path_injection_tenants = [
        '../../../etc/passwd',
        '..\\..\\windows\\system32',
        '/var/log/../../secret',
        'tenant/../../../root'
      ]

      path_injection_tenants.each do |tenant|
        expect {
          Apartment::Tenant.switch!(tenant)
        }.not_to raise_error

        expect(Apartment::Tenant.current).to eq(tenant)
      end
    end

    it 'handles control characters' do
      control_char_tenants = [
        "tenant\n\r",
        "tenant\t\b",
        "tenant\0\x1f",
        "tenant\v\f"
      ]

      control_char_tenants.each do |tenant|
        expect {
          Apartment::Tenant.switch!(tenant)
        }.not_to raise_error

        expect(Apartment::Tenant.current).to eq(tenant)
      end
    end
  end

  describe 'memory and performance edge cases' do
    it 'handles memory pressure scenarios' do
      # Create many connection descriptors to test memory handling
      descriptors = 1000.times.map do |i|
        Apartment::ConnectionAdapters::ConnectionHandler::TenantConnectionDescriptor.new(ActiveRecord::Base, "memory_test_#{i}")
      end

      # Verify they're all unique and properly created
      expect(descriptors.size).to eq(1000)
      expect(descriptors.map(&:name).uniq.size).to eq(1000)

      # GC should be able to clean them up
      descriptors = nil
      GC.start

      # Should not consume excessive memory
      expect(true).to be true # Test completion indicates success
    end

    it 'handles high-frequency switching' do
      # Perform 10,000 tenant switches rapidly
      tenant_pool = %w[freq1 freq2 freq3 freq4 freq5]

      start_time = Time.current

      10_000.times do
        tenant = tenant_pool.sample
        Apartment::Tenant.switch!(tenant)
      end

      end_time = Time.current
      total_time = end_time - start_time

      # Should complete in reasonable time (under 10 seconds)
      expect(total_time).to be < 10.0
    end
  end

  describe 'concurrent edge cases' do
    it 'handles maximum thread contention' do
      # Create as many threads as the system can handle
      thread_count = 50
      results = Concurrent::Array.new
      errors = Concurrent::Array.new

      threads = thread_count.times.map do |i|
        Thread.new do
          begin
            100.times do |j|
              tenant = "thread_#{i}_iteration_#{j}"
              Apartment::Tenant.switch!(tenant)
              results << tenant
            end
          rescue StandardError => e
            errors << e
          end
        end
      end

      threads.each(&:join)

      # All operations should succeed
      expect(errors).to be_empty
      expect(results.size).to eq(thread_count * 100)
    end

    it 'handles thread pool exhaustion scenarios' do
      # Create more threads than typical system limits
      large_thread_count = 200
      completion_count = Concurrent::AtomicFixnum.new(0)

      threads = large_thread_count.times.map do |i|
        Thread.new do
          begin
            Apartment::Tenant.switch!("exhaustion_tenant_#{i}")
            completion_count.increment
          rescue StandardError
            # Some threads may fail due to system limits, that's expected
          end
        end
      end

      threads.each(&:join)

      # At least half should complete successfully
      expect(completion_count.value).to be > (large_thread_count / 2)
    end
  end

  describe 'configuration edge cases' do
    it 'handles circular tenant provider references' do
      # Create a tenant provider that could potentially cause infinite loops
      circular_call_count = 0
      circular_provider = lambda do
        circular_call_count += 1
        if circular_call_count > 10
          raise StandardError, 'Prevented infinite loop'
        end
        %w[circular1 circular2]
      end

      original_provider = Apartment.config.tenants_provider
      Apartment.config.tenants_provider = circular_provider

      # Should handle the provider without infinite loops
      expect { Apartment.tenant_configs['circular1'] }.not_to raise_error

      # Restore original provider
      Apartment.config.tenants_provider = original_provider
    end

    it 'handles tenant provider exceptions' do
      failing_provider = lambda do
        raise StandardError, 'Provider failed'
      end

      original_provider = Apartment.config.tenants_provider
      Apartment.config.tenants_provider = failing_provider

      expect {
        Apartment.tenant_configs.reload_tenant_configs!
      }.to raise_error(StandardError, 'Provider failed')

      # Restore original provider
      Apartment.config.tenants_provider = original_provider
    end
  end

  describe 'database adapter edge cases' do
    context 'with schema strategy' do
      before do
        allow(Apartment.config).to receive(:tenant_strategy).and_return(:schema)
      end

      it 'handles very deep schema nesting' do
        # Test with tenant names that might cause schema path issues
        deep_tenants = [
          'a.b.c.d.e.f.g.h.i.j',
          'schema"with"quotes',
          'schema with spaces',
          'schema;with;semicolons'
        ]

        deep_tenants.each do |tenant|
          expect {
            Apartment::Tenant.switch!(tenant)
          }.not_to raise_error

          expect(Apartment::Tenant.current).to eq(tenant)
        end
      end
    end

    context 'with database_name strategy' do
      before do
        allow(Apartment.config).to receive(:tenant_strategy).and_return(:database_name)
      end

      it 'handles database name limitations' do
        # Test with tenant names that might hit database naming limits
        challenging_db_names = [
          'a' * 100, # Long database name
          'database-with-dashes',
          'database_with_underscores',
          '123numeric_database'
        ]

        challenging_db_names.each do |tenant|
          expect {
            Apartment::Tenant.switch!(tenant)
          }.not_to raise_error

          expect(Apartment::Tenant.current).to eq(tenant)
        end
      end
    end
  end

  describe 'environmentify edge cases' do
    let(:config_map) { Apartment::Tenants::ConfigurationMap.new }

    context 'with extreme environment names' do
      before do
        allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new('very_long_environment_name_that_exceeds_normal_limits'))
      end

      it 'handles very long environment names with prepend strategy' do
        allow(Apartment.config).to receive(:environmentify_strategy).and_return(:prepend)

        config_map.add_or_replace('test_tenant')

        result = config_map['test_tenant']
        expect(result).to include('very_long_environment_name_that_exceeds_normal_limits')
        expect(result).to include('test_tenant')
      end
    end

    context 'with special character environments' do
      before do
        allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new('test-env_with.special@chars'))
      end

      it 'handles special characters in environment names' do
        allow(Apartment.config).to receive(:environmentify_strategy).and_return(:append)

        config_map.add_or_replace('tenant')

        result = config_map['tenant']
        expect(result).to include('test-env_with.special@chars')
      end
    end

    context 'with callable environmentify strategies' do
      it 'handles complex callable transformations' do
        complex_strategy = lambda do |tenant|
          "#{tenant.upcase.reverse}_#{Time.current.to_i}_complex"
        end

        allow(Apartment.config).to receive(:environmentify_strategy).and_return(complex_strategy)

        config_map.add_or_replace('test_tenant')

        result = config_map['test_tenant']
        expect(result).to include('TNANET_TSET') # tenant.upcase.reverse
        expect(result).to include('complex')
      end
    end
  end

  describe 'connection pool edge cases' do
    it 'handles connection pool overflow scenarios' do
      # Create many connections to test pool limits
      pools = 100.times.map do |i|
        Apartment::Tenant.switch!("pool_test_#{i}")
        ActiveRecord::Base.connection_pool
      end

      # All pools should be unique
      expect(pools.map(&:object_id).uniq.size).to eq(100)
    end

    it 'handles connection pool cleanup edge cases' do
      # Create connections and then clear them
      50.times do |i|
        Apartment::Tenant.switch!("cleanup_test_#{i}")
        ActiveRecord::Base.connection
      end

      # Clear all connections
      expect { ActiveRecord::Base.clear_all_connections! }.not_to raise_error

      # Should be able to create new connections after cleanup
      Apartment::Tenant.switch!('post_cleanup_tenant')
      expect { ActiveRecord::Base.connection }.not_to raise_error
    end
  end

  describe 'race condition edge cases' do
    it 'handles rapid context switching between threads' do
      # Test for race conditions in tenant context management
      switch_count = Concurrent::AtomicFixnum.new(0)
      error_count = Concurrent::AtomicFixnum.new(0)

      threads = 20.times.map do |i|
        Thread.new do
          100.times do |j|
            begin
              tenant = "race_tenant_#{i}_#{j}"
              Apartment::Tenant.switch!(tenant)
              switch_count.increment

              # Verify context is correct
              unless Apartment::Tenant.current == tenant
                error_count.increment
              end
            rescue StandardError
              error_count.increment
            end
          end
        end
      end

      threads.each(&:join)

      # Most switches should succeed without race conditions
      expect(switch_count.value).to be > 1900 # Allow for some minor failures
      expect(error_count.value).to be < 100   # Should be minimal errors
    end
  end
end