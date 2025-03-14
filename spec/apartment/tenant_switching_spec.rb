# frozen_string_literal: true

# spec/apartment/tenant_switching_spec.rb

require 'rails_helper'
require 'active_record'
require 'apartment/patches/connection_handling' # Ensure your patches are loaded

# puts '** Establishing initial connection **'
# puts ActiveRecord::Base.establish_connection(:test)&.inspect
# puts "** Initial connection established **\n\n\n"

# Create a dummy table (if needed) and dummy models for testing.
# For the sake of these tests, assume that a connection has been set up.
# You may need to stub out parts of the connection handler if not running an integration test.

# DummyModel is a basic ActiveRecord model.
class DummyModel < ActiveRecord::Base
  self.table_name = 'dummy_models'
end

# PinnedModel simulates a model that is pinned to a specific tenant.
class PinnedModel < ActiveRecord::Base
  include Apartment::Model
  self.table_name = 'dummy_models'
  pinned_tenant 'pinned_tenant'
end

RSpec.describe('Apartment tenant switching') do
  before(:all) do
    # Ensure Apartment has a default tenant (e.g., "public")
    Apartment.configure do |config|
      config.default_tenant = 'public'
      config.configure_postgres do |pg_config|
        pg_config.use_schemas = true
      end
    end
  end

  before do
    # Reset tenant to default and clear AR's connection cache so that
    # connection_specification_name is recomputed.
    Apartment::Tenant.reset
  end

  # describe 'connection_specification_name' do
  #   it 'appends the current tenant to the base connection name' do
  #     # By default, the tenant is the default tenant.
  #     expect(DummyModel.connection_specification_name)
  #       .to(eq("#{DummyModel.name}[#{Apartment.config.default_tenant}]"))
  #   end
  # end

  describe '.switch' do
    # it 'temporarily changes the tenant in a block and reverts afterward' do
    #   original_tenant = Apartment::Tenant.current
    #   new_tenant = 'tenant1'

    #   # expect(DummyModel.connection_specification_name)
    #   #   .to(eq("#{DummyModel.name}[#{original_tenant}]"))

    #   Apartment::Tenant.switch(new_tenant) do
    #     # Within the block, the tenant should be switched.
    #     expect(Apartment::Tenant.current).to(eq(new_tenant))
    #     expect(DummyModel.connection_specification_name)
    #       .to(end_with("[#{new_tenant}]"))
    #   end

    #   # After the block, the tenant reverts.
    #   expect(Apartment::Tenant.current).to(eq(original_tenant))
    #   expect(DummyModel.connection_specification_name)
    #     .to(end_with("[#{original_tenant}]"))
    # end

    # it 'returns a different connection pool when switching tenants' do
    #   # Switch to tenant1 and get a pool.
    #   Apartment::Tenant.switch!('tenant1')
    #   pool_tenant1 = DummyModel.connection_pool

    #   # Switch to tenant2 and get a different pool.
    #   Apartment::Tenant.switch!('tenant2')
    #   pool_tenant2 = DummyModel.connection_pool

    #   expect(pool_tenant1.object_id).not_to(eq(pool_tenant2.object_id))
    # end

    it 'changes the CURRENT_SCHEMA search_path in the connection' do
      # The search_path should include the tenant schema.
      expect(ActiveRecord::Base.connection.execute('SELECT CURRENT_SCHEMA()').first['current_schema'])
        .to(eq('public'))
      Apartment::Tenant.switch('tenant1') do
        # The search_path should include the tenant schema.
        expect(ActiveRecord::Base.connection.execute('SELECT CURRENT_SCHEMA()').first['current_schema'])
          .to(eq(Apartment::Tenant.current))
      end
    end
  end

  # describe '.switch!' do
  #   it 'immediately changes the current tenant' do
  #     Apartment::Tenant.switch!('tenant3')
  #     expect(Apartment::Tenant.current).to(eq('tenant3'))
  #     expect(DummyModel.connection_specification_name)
  #       .to(eq("#{DummyModel.name}[tenant3]"))
  #   end

  #   it 'reuses the same pool if the same tenant is used' do
  #     Apartment::Tenant.switch!('tenant4')
  #     pool_first = DummyModel.connection_pool

  #     # Switch again to the same tenant.
  #     Apartment::Tenant.switch!('tenant4')
  #     pool_second = DummyModel.connection_pool

  #     expect(pool_first.object_id).to(eq(pool_second.object_id))
  #   end
  # end

  # describe 'pinned models' do
  #   it 'always use their pinned tenant regardless of the global tenant' do
  #     # Switch the global tenant to something else.
  #     Apartment::Tenant.switch!('tenant5')
  #     # Even though the global tenant is tenant5, PinnedModel is pinned.
  #     expect(PinnedModel.connection_specification_name)
  #       .to(eq("#{PinnedModel.name}[pinned_tenant]"))
  #     expect(PinnedModel.connection_pool).to(be_present)
  #   end
  # end

  # describe 'with_connection and connected?' do
  #   it 'checks out a connection using the correct pool' do
  #     Apartment::Tenant.switch!('tenant6')
  #     connection = nil
  #     DummyModel.connection_pool.with_connection do |conn|
  #       connection = conn
  #       expect(conn).to(be_present)
  #     end
  #     expect(connection).to(be_present)
  #     # Ensure that connected? returns true.
  #     expect(DummyModel.connected?).to(be(true))
  #   end
  # end

  # describe '.remove_connection' do
  #   it 'removes the connection pool for the current tenant' do
  #     # Establish a connection.
  #     Apartment::Tenant.switch!('tenant7')
  #     pool_before = DummyModel.connection_pool
  #     expect(pool_before).to(be_present)

  #     DummyModel.remove_connection
  #     pool_after = DummyModel.connection_handler.retrieve_connection_pool(
  #       DummyModel.connection_specification_name,
  #       role: DummyModel.current_role,
  #       shard: DummyModel.current_shard,
  #       tenant: Apartment::Tenant.current
  #     )
  #     expect(pool_after).to(be_nil)
  #   end
  # end
end
