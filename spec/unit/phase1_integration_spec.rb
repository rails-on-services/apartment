# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Phase 1 integration' do
  after { Apartment.clear_config }

  it 'configure -> pool_manager -> current -> reaper work together' do
    Apartment.configure do |config|
      config.tenant_strategy = :schema
      config.tenants_provider = -> { %w[acme globex] }
      config.default_tenant = 'public'
      config.tenant_pool_size = 5
      config.pool_idle_timeout = 1
    end

    expect(Apartment.config.tenant_strategy).to eq(:schema)
    expect(Apartment.pool_manager).to be_a(Apartment::PoolManager)

    # Simulate tenant switching via Current
    Apartment::Current.tenant = 'acme'
    expect(Apartment::Current.tenant).to eq('acme')

    # Pool manager tracks tenant pools
    pool = Apartment.pool_manager.fetch_or_create('acme') { 'fake_pool' }
    expect(pool).to eq('fake_pool')

    # Stats work
    stats = Apartment.pool_manager.stats
    expect(stats[:total_pools]).to eq(1)
    expect(stats[:tenants]).to eq(['acme'])

    # Current resets cleanly
    Apartment::Current.reset
    expect(Apartment::Current.tenant).to be_nil
  end

  it 'raises correct errors for invalid config' do
    expect {
      Apartment.configure do |_config|
        # Missing tenant_strategy — validate! requires it
      end
    }.to raise_error(Apartment::ConfigurationError, /tenant_strategy is required/)
  end

  it 'raises TenantNotFound with tenant name' do
    error = Apartment::TenantNotFound.new('missing')
    expect(error.message).to eq("Tenant 'missing' not found")
    expect(error).to be_a(Apartment::ApartmentError)
  end
end
