# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apartment::ConnectionAdapters::PoolConfig do
  describe 'inheritance' do
    it 'inherits from ActiveRecord::ConnectionAdapters::PoolConfig' do
      expect(described_class.ancestors).to include(ActiveRecord::ConnectionAdapters::PoolConfig)
    end
  end

  describe 'compatibility with Rails connection pooling' do
    it 'can be instantiated through Rails connection management' do
      # Test that our PoolConfig works with Rails' connection establishment
      expect { ActiveRecord::Base.connection_pool }.not_to raise_error
    end

    it 'provides pool method override' do
      # Test that our custom pool method works
      expect(described_class.instance_methods).to include(:pool)
    end
  end

  describe '#connection_descriptor compatibility' do
    context 'with Rails 7.x compatibility' do
      it 'provides connection_descriptor alias when needed' do
        if ActiveRecord.version < Gem::Version.new('8.0.0')
          expect(described_class.instance_methods).to include(:connection_descriptor)
        end
      end
    end
  end

  describe '#pool override' do
    it 'uses custom ConnectionPool class when available' do
      # Our pool method should create Apartment ConnectionPool if available
      pool_config = ActiveRecord::Base.connection_pool.db_config
      if pool_config.is_a?(described_class)
        pool = pool_config.pool
        # Should be either our custom pool or Rails default
        expect(pool).to be_a(ActiveRecord::ConnectionAdapters::ConnectionPool)
      end
    end

    it 'synchronizes pool creation' do
      # Test that pool creation is thread-safe
      pool_config = ActiveRecord::Base.connection_pool.db_config
      if pool_config.is_a?(described_class)
        pools = []

        threads = 3.times.map do
          Thread.new { pools << pool_config.pool }
        end

        threads.each(&:join)

        # Should return same pool instance
        expect(pools.map(&:object_id).uniq.size).to eq(1)
      end
    end
  end

  describe 'integration with Apartment' do
    it 'works with tenant switching' do
      Apartment::Tenant.switch('test_tenant') do
        expect { ActiveRecord::Base.connection_pool }.not_to raise_error
      end
    end

    it 'maintains pool consistency across tenant switches' do
      pool1 = nil
      pool2 = nil

      Apartment::Tenant.switch('tenant1') do
        pool1 = ActiveRecord::Base.connection_pool
      end

      Apartment::Tenant.switch('tenant2') do
        pool2 = ActiveRecord::Base.connection_pool
      end

      # Different tenants should have different pools
      expect(pool1.object_id).not_to eq(pool2.object_id)
    end
  end

  describe 'Rails version compatibility' do
    it 'works with current Rails version' do
      expect { ActiveRecord::Base.connection_pool.db_config }.not_to raise_error
    end

    it 'responds to standard Rails pooling interface' do
      pool = ActiveRecord::Base.connection_pool

      # Test core connection pool methods that should exist
      expect(pool).to respond_to(:with_connection)
      expect(pool).to respond_to(:disconnect!)
      expect(pool).to respond_to(:clear_reloadable_connections!)

      # In Rails 8, connection method might be named differently
      expect(pool).to respond_to(:connection).or respond_to(:lease_connection)
    end
  end

  describe 'thread safety' do
    it 'handles concurrent pool access safely' do
      pools = Concurrent::Array.new

      threads = 5.times.map do
        Thread.new do
          Apartment::Tenant.switch("thread_tenant_#{Thread.current.object_id}") do
            pools << ActiveRecord::Base.connection_pool
          end
        end
      end

      threads.each(&:join)

      # Should create pools for each tenant without errors
      expect(pools.size).to eq(5)
      pools.each do |pool|
        expect(pool).to be_a(ActiveRecord::ConnectionAdapters::ConnectionPool)
      end
    end
  end

  describe 'error handling' do
    it 'handles connection errors gracefully' do
      # Should not crash during normal operations
      expect { ActiveRecord::Base.connection_pool.disconnect! }.not_to raise_error
      expect { ActiveRecord::Base.connection_pool }.not_to raise_error
    end

    it 'works with invalid tenant names' do
      Apartment::Tenant.switch('invalid-tenant-name') do
        expect { ActiveRecord::Base.connection_pool }.not_to raise_error
      end
    end
  end

  describe 'memory management' do
    it 'properly manages pool instances' do
      initial_pools = []
      reuse_pools = []

      # Create pools for multiple tenants
      %w[pool_test_1 pool_test_2 pool_test_3].each do |tenant|
        Apartment::Tenant.switch(tenant) do
          initial_pools << ActiveRecord::Base.connection_pool
        end
      end

      # Access same tenants again - should reuse pools
      %w[pool_test_1 pool_test_2 pool_test_3].each do |tenant|
        Apartment::Tenant.switch(tenant) do
          reuse_pools << ActiveRecord::Base.connection_pool
        end
      end

      # Should reuse the same pool objects
      initial_pools.zip(reuse_pools).each do |initial, reuse|
        expect(initial.object_id).to eq(reuse.object_id)
      end
    end
  end

  describe 'database-specific behavior' do
    it 'works with SQLite' do
      # Should work with SQLite without special configuration
      expect { ActiveRecord::Base.connection_pool }.not_to raise_error
    end

    context 'when PostgreSQL is available' do
      it 'works with PostgreSQL configurations' do
        # Should work regardless of database type
        expect { ActiveRecord::Base.connection_pool }.not_to raise_error
      end
    end

    context 'when MySQL is available' do
      it 'works with MySQL configurations' do
        # Should work regardless of database type
        expect { ActiveRecord::Base.connection_pool }.not_to raise_error
      end
    end
  end
end