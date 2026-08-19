# frozen_string_literal: true

require 'spec_helper'
require_relative 'support'

# The lazy adapter build under a live tenant, with a real connection and NO
# pre-assigned adapter — deliberately unlike every other integration spec here, all of
# which assign Apartment.adapter in their setup and so never exercise the build.
#
# configure clears @adapter and activate! does not rebuild it, so the first Apartment
# operation of a process is what triggers the build. When that operation is a tenant
# switch, the build reads the default connection's config through the tenant-aware pool
# lookup, which asks for the adapter it is still building: SystemStackError, on a path
# a job worker, a rake task or rails runner takes routinely. The request path escaped
# only because Elevators::Generic resolves the adapter before it switches.
RSpec.describe('Lazy adapter build under a tenant', :integration,
               skip: (V4_INTEGRATION_AVAILABLE ? false : 'requires ActiveRecord + database gem')) do
  include V4IntegrationHelper

  let(:tmp_dir) { Dir.mktmpdir('apartment_lazy_adapter') }
  let(:tenant) { 'lazy_adapter_tenant' }

  before do
    V4IntegrationHelper.ensure_test_database! unless V4IntegrationHelper.sqlite?
    @config = V4IntegrationHelper.establish_default_connection!(tmp_dir: tmp_dir)

    Apartment.configure do |c|
      c.tenant_strategy = V4IntegrationHelper.tenant_strategy
      c.tenants_provider = -> { [tenant] }
      c.default_tenant = V4IntegrationHelper.default_tenant
      c.check_pending_migrations = false
    end

    # No Apartment.adapter assignment. That is the point of this spec.
    Apartment.activate!
  end

  after do
    V4IntegrationHelper.establish_default_connection!(tmp_dir: tmp_dir)
    Apartment.adapter = V4IntegrationHelper.build_adapter(
      V4IntegrationHelper.default_connection_config(tmp_dir: tmp_dir)
    )
    V4IntegrationHelper.cleanup_tenants!([tenant], Apartment.adapter)
    Apartment.clear_config
    Apartment::Current.reset
    FileUtils.remove_entry(tmp_dir) if File.directory?(tmp_dir)
  end

  it 'builds the adapter rather than recursing to SystemStackError', :aggregate_failures do
    resolved = nil

    expect do
      Apartment::Tenant.switch(tenant) { resolved = ActiveRecord::Base.connection_pool }
    end.not_to(raise_error)

    expect(resolved).not_to(be_nil)
    expect(Apartment.adapter).not_to(be_nil)
  end
end
