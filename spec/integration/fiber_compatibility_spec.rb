# frozen_string_literal: true

require 'spec_helper'
require 'fiber'

describe 'Fiber compatibility' do
  let(:fiber_tenant) { Apartment::Test.next_db }
  let(:main_tenant) { Apartment::Test.next_db }

  before do
    Apartment::Tenant.create(main_tenant)
    Apartment::Tenant.switch!(main_tenant)
    
    Apartment::Tenant.create(fiber_tenant)
    Apartment::Tenant.switch!(main_tenant) # Switch back
  end

  after do
    Apartment.reset
    Apartment::Tenant.drop(main_tenant) rescue nil
    Apartment::Tenant.drop(fiber_tenant) rescue nil
  end

  context 'when switching tenants within a Fiber' do
    it 'maintains isolated database connections per Fiber' do
      # Set up the main tenant
      Apartment::Tenant.switch!(main_tenant)
      ActiveRecord::Base.connection.execute('CREATE TABLE IF NOT EXISTS some_table (id SERIAL PRIMARY KEY, name text)')
      ActiveRecord::Base.connection.execute("INSERT INTO some_table (name) VALUES ('main tenant record')")
      
      # Create a Fiber that switches to another tenant
      fiber = Fiber.new do
        # Switch to a different tenant within the fiber
        Apartment::Tenant.switch!(fiber_tenant)
        
        # Create a table in the fiber tenant
        ActiveRecord::Base.connection.execute('CREATE TABLE IF NOT EXISTS some_table (id SERIAL PRIMARY KEY, name text)')
        ActiveRecord::Base.connection.execute("INSERT INTO some_table (name) VALUES ('fiber tenant record')")
        
        # Get the current tenant name from within the fiber
        fiber_tenant_name = Apartment::Tenant.current
        
        # Get record count from the fiber tenant
        fiber_count = ActiveRecord::Base.connection.execute('SELECT COUNT(*) FROM some_table').first['count']
        
        # Return values to the main thread
        Fiber.yield [fiber_tenant_name, fiber_count]
        
        # Make sure connection is properly maintained when Fiber resumes
        resumed_tenant = Apartment::Tenant.current
        Fiber.yield resumed_tenant
      end
      
      # Run the fiber and get the result
      fiber_result, fiber_count = fiber.resume
      
      # Check that main thread still sees the main tenant
      main_tenant_name = Apartment::Tenant.current
      main_count = ActiveRecord::Base.connection.execute('SELECT COUNT(*) FROM some_table').first['count']
      
      # Resume fiber again to check connection persistence
      resumed_tenant = fiber.resume
      
      # Verify that tenants were properly isolated
      expect(fiber_result).to eq(fiber_tenant)
      expect(fiber_count).to eq(1)
      expect(main_tenant_name).to eq(main_tenant)
      expect(main_count).to eq(1)
      expect(resumed_tenant).to eq(fiber_tenant)
    end

    it 'properly releases connections after fiber completes' do
      # Create multiple fibers that switch tenants
      fibers = []
      
      # Set up the connection pool size checker
      initial_active = ActiveRecord::Base.connection_pool.active_connection_count
      
      5.times do |i|
        fibers << Fiber.new do
          Apartment::Tenant.switch!(fiber_tenant)
          # Do some work
          ActiveRecord::Base.connection.execute('SELECT 1')
          Fiber.yield :done
          
          # Ensure the connection is released at the end of fiber execution
          # This should happen automatically due to our with_connection changes
        end
      end
      
      # Run all fibers
      fibers.each { |f| f.resume }
      
      # Give a short time for any background cleanup
      sleep(0.1)
      
      # Check that connections were released
      final_active = ActiveRecord::Base.connection_pool.active_connection_count
      
      # Check that we don't have more active connections than we started with
      # If connections were properly released, we should have the same or fewer
      expect(final_active).to be <= initial_active + 1 # Allow for the main thread connection
    end
  end
end