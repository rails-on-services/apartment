# frozen_string_literal: true

# spec/support/tenant_context.rb

# This shared context provides the basic setup needed for testing tenant-related
# functionality in a multi-tenant environment. It handles the creation and cleanup
# of test tenants, ensuring each test has a fresh, isolated tenant to work with.
#
# When to use this context:
# - Testing features that operate within a single tenant
# - Testing tenant-specific model behavior
# - Testing tenant isolation
# - Testing tenant-aware controllers or services
# - Any test that needs a clean, isolated tenant environment
#
# Example usage:
#
# RSpec.describe "TenantAwareFeature" do
#   include_context "with tenant setup"
#
#   it "operates within a tenant" do
#     # tenant_name is available as a let variable
#     # The tenant is already created and migrated
#     User.create!(name: "test") # Creates in current tenant
#     expect(User.count).to eq(1)
#   end
# end
#
# This context provides:
# - tenant_name: A unique, generated tenant identifier
# - setup_tenant: Creates and migrates the tenant schema
# - cleanup_tenant: Properly removes the tenant after specs
# - load_schema_for_tenant: Loads the proper database schema version

require_relative 'database_helpers'

RSpec.shared_context('with tenant setup') do
  include DatabaseHelpers

  let(:tenant_name) { generate_tenant_name }

  before do
    setup_tenant(tenant_name)
  end

  after do
    cleanup_tenant(tenant_name)
  end

  def setup_tenant(name)
    create_tenant_schema(name)
    load_schema_for_tenant(name)
  end

  def cleanup_tenant(name)
    Apartment::Tenant.reset
    drop_tenant_schema(name)
  end

  def load_schema_for_tenant(name)
    Apartment::Tenant.switch!(name)
    load_schema_version
  end

  private

  def load_schema_version(version = 3)
    schema_file = Rails.root.join("db/schemas/v#{version}.rb")
    return unless File.exist?(schema_file)

    silence_warnings { load(schema_file) }
  end
end
