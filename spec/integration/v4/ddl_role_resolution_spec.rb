# frozen_string_literal: true

require 'spec_helper'
require_relative 'support'
require_relative 'support/rbac_helper'

# An unresolvable ddl_role, against a real ActiveRecord connection handler.
#
# This exists because unit coverage of the translation was written against a stubbed
# shape Rails never produces — connected_to raising without yielding — and certified a
# feature that did not work. connected_to resolves no pool: it pushes onto
# connected_to_stack and yields, so the failure arrives from inside the block, and only
# a real create proves the classifier sees it there.
RSpec.describe('An unresolvable ddl_role', :integration, :postgresql_only, :rbac,
               skip: (V4_INTEGRATION_AVAILABLE && V4IntegrationHelper.postgresql? ? false : 'requires PG')) do
  include V4IntegrationHelper

  let(:tenant) { 'rbac_unresolvable_role_tenant' }

  before do
    config = V4IntegrationHelper.establish_default_connection!
    # Registers :writing and :db_manager. :nope is deliberately absent.
    RbacHelper.setup_connects_to!(config)

    Apartment.configure do |c|
      c.tenant_strategy = :schema
      c.tenants_provider = -> { [tenant] }
      c.default_tenant = 'public'
      c.ddl_role = :nope
      c.check_pending_migrations = false
    end

    Apartment.adapter = V4IntegrationHelper.build_adapter(config)
    Apartment.activate!
  end

  after do
    RbacHelper.teardown_rbac_connections!

    # ddl_role has to go before cleanup: drop wraps its engine call in the same role,
    # so tearing down under :nope would raise the very error under test.
    Apartment.clear_config
    config = V4IntegrationHelper.establish_default_connection!
    Apartment.configure do |c|
      c.tenant_strategy = :schema
      c.tenants_provider = -> { [tenant] }
      c.default_tenant = 'public'
    end
    Apartment.adapter = V4IntegrationHelper.build_adapter(config)
    V4IntegrationHelper.cleanup_tenants!([tenant], Apartment.adapter)
    Apartment.clear_config
    Apartment::Current.reset
  end

  # The cause chain is ONE link, and asserting that is the point: the AR error is the
  # ConfigurationError's immediate cause. ConnectionHandling used to relabel the role
  # failure as ApartmentError first — its rescue was method-level and so covered the
  # `return super` guards a default-path lookup takes — which put a wrapper in between
  # and forced MigrationRole to unwrap a layer before classifying. If that relabelling
  # ever comes back, #cause is the wrapper and this example fails.
  #
  # Asserted against ConnectionNotEstablished rather than the ConnectionNotDefined
  # subclass Rails 8 raises here, because that subclass does not exist before Rails 8.0
  # and this lane runs on the Rails floor too. The superclass is what both versions
  # satisfy.
  it 'names ddl_role when a create cannot enter the role', :aggregate_failures do
    raised = nil
    begin
      Apartment.adapter.create(tenant)
    rescue StandardError => e
      raised = e
    end

    expect(raised).to(be_a(Apartment::ConfigurationError))
    expect(raised.message).to(match(/ddl_role.*:nope/))
    expect(raised.message).to(match(/ActiveRecord::ConnectionNot(Defined|Established)/))
    expect(raised.cause).to(be_a(ActiveRecord::ConnectionNotEstablished))
  end

  it 'creates no container, because the failure precedes the first statement' do
    Apartment.adapter.create(tenant)
  rescue Apartment::ConfigurationError
    conn = ActiveRecord::Base.connection
    expect(conn.select_value("SELECT to_regnamespace(#{conn.quote(tenant)}) IS NOT NULL")).to(be(false))
  end
end
