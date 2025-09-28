# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apartment::ConnectionAdapters::ConnectionHandler do
  let(:handler) { described_class.new }
  let(:tenant_name) { 'test_tenant' }
  let(:base_config) { Apartment.connection_class.configurations.resolve(:test) }

  before(:all) do
    Apartment.configure do |config|
      config.default_tenant = 'public'
      config.tenant_strategy = :schema
      config.tenants_provider = -> { %w[tenant1 tenant2 test_tenant] }
    end
  end

  before { Apartment::Tenant.reset }

  describe 'inheritance' do
    it 'inherits from ActiveRecord::ConnectionAdapters::ConnectionHandler' do
      expect(handler).to be_a(ActiveRecord::ConnectionAdapters::ConnectionHandler)
    end
  end

  describe '#retrieve_connection_pool' do
    context 'with tenant-aware connection specification' do
      it 'returns tenant-specific connection pool' do
        spec = Apartment::ConnectionAdapters::ConnectionHandler::TenantConnectionDescriptor.new(Apartment.connection_class, tenant_name)

        pool = handler.retrieve_connection_pool(spec)
        expect(pool).to be_a(ActiveRecord::ConnectionAdapters::ConnectionPool)
      end

      it 'creates separate pools for different tenants' do
        spec1 = Apartment::ConnectionAdapters::ConnectionHandler::TenantConnectionDescriptor.new(Apartment.connection_class, 'tenant1')
        spec2 = Apartment::ConnectionAdapters::ConnectionHandler::TenantConnectionDescriptor.new(Apartment.connection_class, 'tenant2')

        pool1 = handler.retrieve_connection_pool(spec1)
        pool2 = handler.retrieve_connection_pool(spec2)

        expect(pool1.object_id).not_to eq(pool2.object_id)
      end

      it 'reuses existing pools for same tenant' do
        spec = Apartment::ConnectionAdapters::ConnectionHandler::TenantConnectionDescriptor.new(Apartment.connection_class, tenant_name)

        pool1 = handler.retrieve_connection_pool(spec)
        pool2 = handler.retrieve_connection_pool(spec)

        expect(pool1.object_id).to eq(pool2.object_id)
      end
    end

    context 'with standard connection specification' do
      it 'delegates to parent implementation' do
        spec = Apartment.connection_class.connection_specification_name

        expect { handler.retrieve_connection_pool(spec) }.not_to raise_error
      end
    end
  end

  describe '#connected?' do
    it 'checks tenant-specific connection status' do
      spec = Apartment::ConnectionAdapters::ConnectionHandler::TenantConnectionDescriptor.new(Apartment.connection_class, tenant_name)

      expect(handler.connected?(spec)).to be_in([true, false])
    end
  end

  describe '#remove_connection_pool' do
    it 'removes tenant-specific connection pool' do
      spec = Apartment::ConnectionAdapters::ConnectionHandler::TenantConnectionDescriptor.new(Apartment.connection_class, tenant_name)

      # Create pool first
      handler.retrieve_connection_pool(spec)

      # Remove it
      result = handler.remove_connection_pool(spec)
      expect(result).to be_a(ActiveRecord::ConnectionAdapters::ConnectionPool)
    end

    it 'returns nil for non-existent pools' do
      spec = Apartment::ConnectionAdapters::ConnectionHandler::TenantConnectionDescriptor.new(Apartment.connection_class, 'nonexistent_tenant')

      result = handler.remove_connection_pool(spec)
      expect(result).to be_nil
    end
  end

  describe '#clear_active_connections!' do
    it 'clears active connections without errors' do
      # Create some tenant connections
      spec1 = Apartment::ConnectionAdapters::ConnectionHandler::TenantConnectionDescriptor.new(Apartment.connection_class, 'tenant1')
      spec2 = Apartment::ConnectionAdapters::ConnectionHandler::TenantConnectionDescriptor.new(Apartment.connection_class, 'tenant2')

      handler.retrieve_connection_pool(spec1)
      handler.retrieve_connection_pool(spec2)

      expect { handler.clear_active_connections! }.not_to raise_error
    end
  end

  describe '#clear_reloadable_connections!' do
    it 'clears reloadable connections without errors' do
      # Create some tenant connections
      spec = Apartment::ConnectionAdapters::ConnectionHandler::TenantConnectionDescriptor.new(Apartment.connection_class, tenant_name)
      handler.retrieve_connection_pool(spec)

      expect { handler.clear_reloadable_connections! }.not_to raise_error
    end
  end

  describe '#clear_all_connections!' do
    it 'clears all connections without errors' do
      # Create some tenant connections
      spec = Apartment::ConnectionAdapters::ConnectionHandler::TenantConnectionDescriptor.new(Apartment.connection_class, tenant_name)
      handler.retrieve_connection_pool(spec)

      expect { handler.clear_all_connections! }.not_to raise_error
    end
  end

  describe 'thread safety' do
    it 'handles concurrent pool creation safely' do
      tenant_names = %w[concurrent1 concurrent2 concurrent3]
      pools = Concurrent::Hash.new

      threads = tenant_names.map do |name|
        Thread.new do
          spec = Apartment::ConnectionAdapters::ConnectionHandler::TenantConnectionDescriptor.new(Apartment.connection_class, name)
          pools[name] = handler.retrieve_connection_pool(spec)
        end
      end

      threads.each(&:join)

      expect(pools.size).to eq(3)
      expect(pools.values.map(&:object_id).uniq.size).to eq(3)
    end
  end

  describe 'integration with Apartment configuration' do
    context 'with schema strategy' do
      before do
        allow(Apartment.config).to receive(:tenant_strategy).and_return(:schema)
      end

      it 'creates pools with schema-specific configuration' do
        spec = Apartment::ConnectionAdapters::ConnectionHandler::TenantConnectionDescriptor.new(Apartment.connection_class, tenant_name)

        pool = handler.retrieve_connection_pool(spec)
        expect(pool).to be_present
      end
    end

    context 'with database_name strategy' do
      before do
        allow(Apartment.config).to receive(:tenant_strategy).and_return(:database_name)
      end

      it 'creates pools with database-specific configuration' do
        spec = Apartment::ConnectionAdapters::ConnectionHandler::TenantConnectionDescriptor.new(Apartment.connection_class, tenant_name)

        pool = handler.retrieve_connection_pool(spec)
        expect(pool).to be_present
      end
    end
  end

  describe 'error handling' do
    it 'handles invalid tenant configurations gracefully' do
      spec = Apartment::ConnectionAdapters::ConnectionHandler::TenantConnectionDescriptor.new(Apartment.connection_class, 'invalid_tenant')

      # Should not raise error during pool creation
      expect { handler.retrieve_connection_pool(spec) }.not_to raise_error
    end
  end
end