# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apartment::ConnectionAdapters::PoolManager do
  let(:connection_class) { Apartment.connection_class }
  let(:tenant_name) { 'test_tenant' }
  let(:base_config) { connection_class.configurations.resolve(:test) }
  let(:pool_manager) { described_class.new(connection_class) }

  before(:all) do
    Apartment.configure do |config|
      config.default_tenant = 'public'
      config.tenant_strategy = :schema
      config.tenants_provider = -> { %w[tenant1 tenant2 test_tenant] }
    end
  end

  before { Apartment::Tenant.reset }

  describe 'initialization' do
    it 'stores the connection class' do
      expect(pool_manager.instance_variable_get(:@connection_class)).to eq(connection_class)
    end

    it 'initializes empty pool storage' do
      pools = pool_manager.instance_variable_get(:@role_shard_to_pool)
      expect(pools).to be_a(Hash)
      expect(pools).to be_empty
    end
  end

  describe '#get_pool' do
    let(:role) { :writing }
    let(:shard) { :default }

    context 'with first access to tenant' do
      it 'creates new connection pool' do
        pool = pool_manager.get_pool(tenant_name, role: role, shard: shard)

        expect(pool).to be_a(ActiveRecord::ConnectionAdapters::ConnectionPool)
      end

      it 'stores pool for reuse' do
        pool1 = pool_manager.get_pool(tenant_name, role: role, shard: shard)
        pool2 = pool_manager.get_pool(tenant_name, role: role, shard: shard)

        expect(pool1.object_id).to eq(pool2.object_id)
      end
    end

    context 'with different tenants' do
      it 'creates separate pools' do
        pool1 = pool_manager.get_pool('tenant1', role: role, shard: shard)
        pool2 = pool_manager.get_pool('tenant2', role: role, shard: shard)

        expect(pool1.object_id).not_to eq(pool2.object_id)
      end
    end

    context 'with different roles' do
      it 'creates separate pools for different roles' do
        pool1 = pool_manager.get_pool(tenant_name, role: :writing, shard: shard)
        pool2 = pool_manager.get_pool(tenant_name, role: :reading, shard: shard)

        expect(pool1.object_id).not_to eq(pool2.object_id)
      end
    end

    context 'with different shards' do
      it 'creates separate pools for different shards' do
        pool1 = pool_manager.get_pool(tenant_name, role: role, shard: :shard1)
        pool2 = pool_manager.get_pool(tenant_name, role: role, shard: :shard2)

        expect(pool1.object_id).not_to eq(pool2.object_id)
      end
    end

    context 'with default parameters' do
      it 'uses current role and shard when not specified' do
        allow(ActiveRecord::Base).to receive(:current_role).and_return(:custom_role)
        allow(ActiveRecord::Base).to receive(:current_shard).and_return(:custom_shard)

        pool = pool_manager.get_pool(tenant_name)

        expect(pool).to be_a(ActiveRecord::ConnectionAdapters::ConnectionPool)
      end
    end
  end

  describe '#each_pool' do
    before do
      # Create some pools
      pool_manager.get_pool('tenant1', role: :writing, shard: :default)
      pool_manager.get_pool('tenant2', role: :writing, shard: :default)
      pool_manager.get_pool('tenant1', role: :reading, shard: :default)
    end

    it 'yields each pool' do
      pools = []
      pool_manager.each_pool { |pool| pools << pool }

      expect(pools.size).to eq(3)
      pools.each do |pool|
        expect(pool).to be_a(ActiveRecord::ConnectionAdapters::ConnectionPool)
      end
    end

    it 'returns enumerator when no block given' do
      result = pool_manager.each_pool

      expect(result).to be_a(Enumerator)
      expect(result.to_a.size).to eq(3)
    end
  end

  describe '#remove_pool' do
    let(:role) { :writing }
    let(:shard) { :default }

    it 'removes and returns existing pool' do
      # Create pool first
      original_pool = pool_manager.get_pool(tenant_name, role: role, shard: shard)

      # Remove it
      removed_pool = pool_manager.remove_pool(tenant_name, role: role, shard: shard)

      expect(removed_pool).to eq(original_pool)

      # Verify it's gone
      new_pool = pool_manager.get_pool(tenant_name, role: role, shard: shard)
      expect(new_pool.object_id).not_to eq(original_pool.object_id)
    end

    it 'returns nil for non-existent pool' do
      result = pool_manager.remove_pool('nonexistent', role: role, shard: shard)

      expect(result).to be_nil
    end
  end

  describe '#connected?' do
    let(:role) { :writing }
    let(:shard) { :default }

    it 'returns false before pool creation' do
      result = pool_manager.connected?(tenant_name, role: role, shard: shard)

      expect(result).to be false
    end

    it 'returns true after pool creation' do
      pool_manager.get_pool(tenant_name, role: role, shard: shard)

      result = pool_manager.connected?(tenant_name, role: role, shard: shard)

      expect(result).to be true
    end
  end

  describe 'thread safety' do
    it 'handles concurrent pool access safely' do
      tenant_names = %w[concurrent1 concurrent2 concurrent3]
      pools = Concurrent::Hash.new

      threads = tenant_names.map do |name|
        Thread.new do
          pools[name] = pool_manager.get_pool(name, role: :writing, shard: :default)
        end
      end

      threads.each(&:join)

      expect(pools.size).to eq(3)
      expect(pools.values.map(&:object_id).uniq.size).to eq(3)
    end

    it 'handles concurrent pool removal safely' do
      # Create pools
      tenant_names = %w[remove1 remove2 remove3]
      tenant_names.each do |name|
        pool_manager.get_pool(name, role: :writing, shard: :default)
      end

      # Remove them concurrently
      results = Concurrent::Array.new
      threads = tenant_names.map do |name|
        Thread.new do
          result = pool_manager.remove_pool(name, role: :writing, shard: :default)
          results << result if result
        end
      end

      threads.each(&:join)

      expect(results.size).to eq(3)
    end
  end

  describe 'pool key generation' do
    it 'creates unique keys for different tenant/role/shard combinations' do
      # This tests the internal pool_key method indirectly
      pool1 = pool_manager.get_pool('tenant1', role: :writing, shard: :default)
      pool2 = pool_manager.get_pool('tenant1', role: :reading, shard: :default)
      pool3 = pool_manager.get_pool('tenant1', role: :writing, shard: :custom)
      pool4 = pool_manager.get_pool('tenant2', role: :writing, shard: :default)

      pools = [pool1, pool2, pool3, pool4]
      unique_pools = pools.map(&:object_id).uniq

      expect(unique_pools.size).to eq(4)
    end
  end

  describe 'integration with database configuration resolution' do
    context 'with schema strategy' do
      before do
        allow(Apartment.config).to receive(:tenant_strategy).and_return(:schema)
      end

      it 'creates pools with correct schema configuration' do
        pool = pool_manager.get_pool(tenant_name, role: :writing, shard: :default)

        expect(pool).to be_a(ActiveRecord::ConnectionAdapters::ConnectionPool)
        expect(pool.db_config).to be_present
      end
    end

    context 'with database_name strategy' do
      before do
        allow(Apartment.config).to receive(:tenant_strategy).and_return(:database_name)
      end

      it 'creates pools with correct database configuration' do
        pool = pool_manager.get_pool(tenant_name, role: :writing, shard: :default)

        expect(pool).to be_a(ActiveRecord::ConnectionAdapters::ConnectionPool)
        expect(pool.db_config).to be_present
      end
    end
  end

  describe 'error handling' do
    it 'handles invalid tenant configurations gracefully' do
      # Should not raise error during pool creation
      expect {
        pool_manager.get_pool('invalid_tenant', role: :writing, shard: :default)
      }.not_to raise_error
    end

    it 'handles database connection errors gracefully' do
      # Mock a configuration that would cause connection errors
      allow(Apartment::DatabaseConfigurations).to receive(:resolve_for_tenant).and_raise(StandardError.new('Connection failed'))

      expect {
        pool_manager.get_pool(tenant_name, role: :writing, shard: :default)
      }.to raise_error(StandardError, 'Connection failed')
    end
  end

  describe 'memory management' do
    it 'properly cleans up pools when removed' do
      pool = pool_manager.get_pool(tenant_name, role: :writing, shard: :default)
      original_object_id = pool.object_id

      expect(pool).to receive(:disconnect!).and_call_original
      removed_pool = pool_manager.remove_pool(tenant_name, role: :writing, shard: :default)

      expect(removed_pool.object_id).to eq(original_object_id)
    end
  end
end