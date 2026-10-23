# frozen_string_literal: true

require 'spec_helper'
require_relative 'support'
require 'apartment/concerns/model'

# With force_separate_pinned_pool, a pinned model gets a connection of its own
# (establish_connection) and ConnectionHandling hands back the model's own pool.
# Rails looks that pool up by the model's connection name *and the current
# role*, so a pinned model needs a pool for every role the app connects to:
# with only a :writing pool, reading it inside connected_to(role: :reading) —
# the replica routing an app sets up with connects_to — raised
# ActiveRecord::ConnectionNotDefined.
RSpec.describe('v4 separate pinned pool roles', :integration,
               skip: (V4_INTEGRATION_AVAILABLE && V4IntegrationHelper.postgresql? ? false : 'requires PostgreSQL')) do
  include V4IntegrationHelper

  let(:tenant) { "pinned_roles_#{SecureRandom.hex(4)}" }
  let(:reading_role) { true }

  before do
    V4IntegrationHelper.ensure_test_database!
    config = V4IntegrationHelper.establish_default_connection!
    V4IntegrationHelper.register_reading_role!(config) if reading_role

    Apartment.configure do |c|
      c.tenant_strategy = :schema
      c.tenants_provider = -> { [tenant] }
      c.default_tenant = 'public'
      c.check_pending_migrations = false
      c.force_separate_pinned_pool = true
    end
    Apartment.adapter = V4IntegrationHelper.build_adapter(config)
    Apartment.activate!
    Apartment.adapter.create(tenant)

    ActiveRecord::Base.connection.create_table(:pinned_role_settings, force: true) { |t| t.string(:label) }
    ActiveRecord::Base.connection.execute("INSERT INTO pinned_role_settings (label) VALUES ('default_row')")
    Apartment::Tenant.switch(tenant) do
      ActiveRecord::Base.connection.create_table(:pinned_role_settings, force: true) { |t| t.string(:label) }
      ActiveRecord::Base.connection.execute("INSERT INTO pinned_role_settings (label) VALUES ('tenant_row')")
    end

    stub_const('ApplicationRecord', Class.new(ActiveRecord::Base) { self.abstract_class = true })
    stub_const('PinnedRoleSetting', Class.new(ApplicationRecord) do
      self.table_name = 'pinned_role_settings'
      include Apartment::Model
    end)
    PinnedRoleSetting.pin_tenant
    Apartment.process_pinned_model(PinnedRoleSetting)
  end

  after do
    ActiveRecord::Base.connection.drop_table(:pinned_role_settings, if_exists: true)
    V4IntegrationHelper.cleanup_tenants!([tenant], Apartment.adapter)
    Apartment.clear_config
    Apartment::Current.reset
  end

  def pool_for(role)
    ActiveRecord::Base.connection_handler.retrieve_connection_pool(
      PinnedRoleSetting.connection_specification_name, role:
    )
  end

  it 'reads the default tenant through the :writing pool, as before' do
    Apartment::Tenant.switch(tenant) do
      expect(PinnedRoleSetting.pluck(:label)).to(eq(['default_row']))
    end
  end

  it 'reads the default tenant inside connected_to(role: :reading)' do
    labels = ActiveRecord::Base.connected_to(role: :reading) do
      Apartment::Tenant.switch(tenant) { PinnedRoleSetting.pluck(:label) }
    end

    expect(labels).to(eq(['default_row']))
  end

  it "gives the :reading pool the :reading connection's config and the default tenant's search path" do
    reading = pool_for(:reading)

    expect(reading).not_to(equal(pool_for(:writing)))
    expect(reading.db_config.name).to(eq('primary_reading'))
    expect(reading.db_config.configuration_hash[:schema_search_path]).to(eq('"public"'))
  end

  context 'when the app connects with the :writing role only' do
    let(:reading_role) { false }

    it 'establishes the :writing pool alone' do
      expect(pool_for(:writing)).not_to(be_nil)
      expect(pool_for(:reading)).to(be_nil)
    end
  end
end
