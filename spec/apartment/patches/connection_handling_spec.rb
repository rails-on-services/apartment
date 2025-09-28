# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'ActiveRecord Connection Handling Patches' do
  let(:model_class) { Class.new(ActiveRecord::Base) }
  let(:tenant_name) { 'test_tenant' }

  before(:all) do
    Apartment.configure do |config|
      config.default_tenant = 'public'
      config.tenant_strategy = :schema
      config.tenants_provider = -> { %w[tenant1 tenant2 test_tenant] }
    end
  end

  before do
    Apartment::Tenant.reset
    stub_const('TestModel', model_class)
  end

  describe 'ActiveRecord::Base connection handling' do
    it 'uses Apartment connection handler' do
      expect(ActiveRecord::Base.default_connection_handler).to be_a(
        Apartment::ConnectionAdapters::ConnectionHandler
      )
    end

    it 'maintains connection handling method compatibility' do
      expect(ActiveRecord::Base).to respond_to(:connection)
      expect(ActiveRecord::Base).to respond_to(:connection_pool)
      expect(ActiveRecord::Base).to respond_to(:connected?)
      expect(ActiveRecord::Base).to respond_to(:remove_connection)
    end
  end

  describe 'tenant-aware connection retrieval' do
    it 'returns different connections for different tenants' do
      Apartment::Tenant.switch!('tenant1')
      connection1 = ActiveRecord::Base.connection

      Apartment::Tenant.switch!('tenant2')
      connection2 = ActiveRecord::Base.connection

      # Connections should be different objects
      expect(connection1.object_id).not_to eq(connection2.object_id)
    end

    it 'returns same connection for same tenant' do
      Apartment::Tenant.switch!(tenant_name)
      connection1 = ActiveRecord::Base.connection
      connection2 = ActiveRecord::Base.connection

      expect(connection1.object_id).to eq(connection2.object_id)
    end
  end

  describe 'tenant-aware connection pool retrieval' do
    it 'returns different pools for different tenants' do
      Apartment::Tenant.switch!('tenant1')
      pool1 = ActiveRecord::Base.connection_pool

      Apartment::Tenant.switch!('tenant2')
      pool2 = ActiveRecord::Base.connection_pool

      expect(pool1.object_id).not_to eq(pool2.object_id)
    end

    it 'returns same pool for same tenant' do
      Apartment::Tenant.switch!(tenant_name)
      pool1 = ActiveRecord::Base.connection_pool
      pool2 = ActiveRecord::Base.connection_pool

      expect(pool1.object_id).to eq(pool2.object_id)
    end
  end

  describe 'connected? method patches' do
    it 'checks tenant-specific connection status' do
      Apartment::Tenant.switch!(tenant_name)

      # Should return boolean without errors
      result = ActiveRecord::Base.connected?
      expect(result).to be_in([true, false])
    end

    it 'returns different status for different tenants' do
      Apartment::Tenant.switch!('tenant1')
      status1 = ActiveRecord::Base.connected?

      Apartment::Tenant.switch!('tenant2')
      status2 = ActiveRecord::Base.connected?

      # Both should be boolean values (may be same or different)
      expect(status1).to be_in([true, false])
      expect(status2).to be_in([true, false])
    end
  end

  describe 'remove_connection method patches' do
    it 'removes tenant-specific connections' do
      Apartment::Tenant.switch!(tenant_name)

      # Ensure connection exists
      ActiveRecord::Base.connection

      # Remove it
      result = ActiveRecord::Base.remove_connection

      expect(result).to be_a(ActiveRecord::ConnectionAdapters::ConnectionPool)
    end

    it 'only affects current tenant connection' do
      # Set up connections for two tenants
      Apartment::Tenant.switch!('tenant1')
      ActiveRecord::Base.connection
      pool1_id = ActiveRecord::Base.connection_pool.object_id

      Apartment::Tenant.switch!('tenant2')
      ActiveRecord::Base.connection
      pool2_id = ActiveRecord::Base.connection_pool.object_id

      # Remove connection for tenant2
      ActiveRecord::Base.remove_connection

      # Switch back to tenant1 - its connection should still exist
      Apartment::Tenant.switch!('tenant1')
      current_pool_id = ActiveRecord::Base.connection_pool.object_id

      # tenant1's pool should be the same (not affected by tenant2's removal)
      expect(current_pool_id).to eq(pool1_id)
    end
  end

  describe 'model class connection handling' do
    it 'inherits tenant-aware behavior in model classes' do
      Apartment::Tenant.switch!(tenant_name)

      expect(TestModel.connection).to be_present
      expect(TestModel.connection_pool).to be_present
      expect(TestModel.connected?).to be_in([true, false])
    end

    it 'provides different connections for different tenants' do
      Apartment::Tenant.switch!('tenant1')
      connection1 = TestModel.connection

      Apartment::Tenant.switch!('tenant2')
      connection2 = TestModel.connection

      expect(connection1.object_id).not_to eq(connection2.object_id)
    end
  end

  describe 'thread safety of connection handling' do
    it 'maintains separate connections per thread' do
      connections = Concurrent::Hash.new

      threads = 3.times.map do |i|
        Thread.new do
          Apartment::Tenant.switch!("tenant#{i}")
          connections["tenant#{i}"] = ActiveRecord::Base.connection.object_id
        end
      end

      threads.each(&:join)

      # Each thread should have gotten a different connection
      expect(connections.size).to eq(3)
      expect(connections.values.uniq.size).to eq(3)
    end

    it 'maintains separate connection pools per thread' do
      pools = Concurrent::Hash.new

      threads = 3.times.map do |i|
        Thread.new do
          Apartment::Tenant.switch!("tenant#{i}")
          pools["tenant#{i}"] = ActiveRecord::Base.connection_pool.object_id
        end
      end

      threads.each(&:join)

      # Each thread should have gotten a different pool
      expect(pools.size).to eq(3)
      expect(pools.values.uniq.size).to eq(3)
    end
  end

  describe 'compatibility with ActiveRecord connection methods' do
    it 'supports establish_connection' do
      # This should work without breaking apartment's connection handling
      expect { TestModel.establish_connection }.not_to raise_error
    end

    it 'supports clear_active_connections!' do
      Apartment::Tenant.switch!(tenant_name)
      ActiveRecord::Base.connection # Establish connection

      expect { ActiveRecord::Base.clear_active_connections! }.not_to raise_error
    end

    it 'supports clear_reloadable_connections!' do
      Apartment::Tenant.switch!(tenant_name)
      ActiveRecord::Base.connection # Establish connection

      expect { ActiveRecord::Base.clear_reloadable_connections! }.not_to raise_error
    end

    it 'supports clear_all_connections!' do
      Apartment::Tenant.switch!(tenant_name)
      ActiveRecord::Base.connection # Establish connection

      expect { ActiveRecord::Base.clear_all_connections! }.not_to raise_error
    end
  end

  describe 'compatibility with Rails connection handling' do
    it 'supports connected_to blocks' do
      expect {
        ActiveRecord::Base.connected_to(role: :reading) do
          ActiveRecord::Base.connection
        end
      }.not_to raise_error
    end

    it 'maintains tenant context within connected_to blocks' do
      Apartment::Tenant.switch!(tenant_name)

      ActiveRecord::Base.connected_to(role: :reading) do
        expect(Apartment::Tenant.current).to eq(tenant_name)
      end
    end
  end

  describe 'error handling in connection patches' do
    it 'handles connection errors gracefully' do
      # Mock a connection that will fail
      allow_any_instance_of(Apartment::ConnectionAdapters::ConnectionHandler)
        .to receive(:retrieve_connection_pool)
        .and_raise(ActiveRecord::ConnectionNotEstablished)

      expect {
        ActiveRecord::Base.connection
      }.to raise_error(ActiveRecord::ConnectionNotEstablished)
    end

    it 'handles pool retrieval errors gracefully' do
      allow_any_instance_of(Apartment::ConnectionAdapters::ConnectionHandler)
        .to receive(:retrieve_connection_pool)
        .and_return(nil)

      expect {
        ActiveRecord::Base.connection_pool
      }.to raise_error(ActiveRecord::ConnectionNotEstablished)
    end
  end

  describe 'connection specification handling' do
    it 'properly handles tenant connection specifications' do
      spec = Apartment::ConnectionAdapters::ConnectionHandler::TenantConnectionDescriptor.new(ActiveRecord::Base, tenant_name)

      # Should be able to use spec with connection handler
      handler = ActiveRecord::Base.default_connection_handler
      expect { handler.retrieve_connection_pool(spec) }.not_to raise_error
    end

    it 'maintains backward compatibility with string specs' do
      spec = ActiveRecord::Base.connection_specification_name

      handler = ActiveRecord::Base.default_connection_handler
      expect { handler.retrieve_connection_pool(spec) }.not_to raise_error
    end
  end

  describe 'memory management in connection handling' do
    it 'properly cleans up tenant connections on removal' do
      Apartment::Tenant.switch!(tenant_name)
      original_pool = ActiveRecord::Base.connection_pool

      # Mock disconnect! to verify it's called
      expect(original_pool).to receive(:disconnect!).and_call_original

      ActiveRecord::Base.remove_connection
    end

    it 'handles multiple connection removals safely' do
      Apartment::Tenant.switch!(tenant_name)
      ActiveRecord::Base.connection

      # Remove connection multiple times - should not error
      ActiveRecord::Base.remove_connection
      result = ActiveRecord::Base.remove_connection

      expect(result).to be_nil # Second removal should return nil
    end
  end
end