# frozen_string_literal: true

# spec/support/adapter_testing_contexts.rb

# This shared context provides the necessary setup for testing different database
# adapters in Apartment. It handles adapter initialization, tenant switching, and
# cleanup while providing helper methods for testing adapter-specific functionality.
#
# When to use this context:
# - Testing new database adapters
# - Testing adapter-specific features (schemas, databases, etc.)
# - Testing low-level tenant switching behavior
# - Testing adapter configuration options
# - Testing adapter edge cases and error conditions
#
# Example usage:
#
# RSpec.describe Apartment::Adapters::PostgresqlAdapter do
#   include_context "with adapter setup"
#
#   it "switches tenants correctly" do
#     adapter.switch!(tenant_name) do
#       # Test adapter-specific behavior
#       expect(adapter.current).to eq(tenant_name)
#     end
#   end
# end
#
# This context provides:
# - adapter: Instance of the adapter being tested
# - tenant_name: A unique tenant identifier
# - another_tenant: A second unique tenant identifier
# - connection: The current database connection
# - config: Database configuration for the current adapter
# - in_tenant: Helper method for switching tenants in a block
# - cleanup_tenant: Proper tenant cleanup between tests
#
# The context automatically handles:
# - Adapter initialization with proper config
# - Database connection management
# - Tenant cleanup after each test
# - Cross-database adapter testing

require_relative 'database_helpers'

RSpec.shared_context('with adapter setup', :adapter_test) do
  include DatabaseHelpers

  let(:adapter) { described_class.new(config) }
  let(:tenant_name) { generate_tenant_name }
  let(:another_tenant) { generate_tenant_name }
  let(:default_tenant) { Apartment.default_tenant || 'public' }
  let(:connection) { ActiveRecord::Base.connection }
  let(:config) do
    db = RSpec.current_example.metadata.fetch(:database, :postgresql)
    Apartment::Test.config['connections'][db.to_s]&.symbolize_keys
  end

  after do
    cleanup_tenant(tenant_name)
    cleanup_tenant(another_tenant)
  end

  def cleanup_tenant(name)
    drop_tenant_schema(name, adapter)
  end

  def in_tenant(name, &block)
    adapter.switch(name, &block)
  end
end
