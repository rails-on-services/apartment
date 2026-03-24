# frozen_string_literal: true

require 'spec_helper'

RSpec.describe('Phase 1 integration') do
  after { Apartment.clear_config }

  it 'configure -> pool_manager -> current -> reaper work together' do
    Apartment.configure do |config|
      config.tenant_strategy = :schema
      config.tenants_provider = -> { %w[acme globex] }
      config.default_tenant = 'public'
      config.tenant_pool_size = 5
      config.pool_idle_timeout = 1
    end

    expect(Apartment.config.tenant_strategy).to(eq(:schema))
    expect(Apartment.pool_manager).to(be_a(Apartment::PoolManager))

    # Simulate tenant switching via Current
    Apartment::Current.tenant = 'acme'
    expect(Apartment::Current.tenant).to(eq('acme'))

    # Pool manager tracks tenant pools
    pool = Apartment.pool_manager.fetch_or_create('acme') { 'fake_pool' }
    expect(pool).to(eq('fake_pool'))

    # Stats work
    stats = Apartment.pool_manager.stats
    expect(stats[:total_pools]).to(eq(1))
    expect(stats[:tenants]).to(eq(['acme']))

    # Current resets cleanly
    Apartment::Current.reset
    expect(Apartment::Current.tenant).to(be_nil)
  end

  it 'raises ConfigurationError when tenant_strategy missing' do
    expect do
      Apartment.configure do |config|
        config.tenants_provider = -> { [] }
      end
    end.to(raise_error(Apartment::ConfigurationError, /tenant_strategy/))
  end

  it 'raises ConfigurationError when tenants_provider missing' do
    expect do
      Apartment.configure do |config|
        config.tenant_strategy = :schema
      end
    end.to(raise_error(Apartment::ConfigurationError, /tenants_provider/))
  end

  it 'raises TenantNotFound with accessible tenant name' do
    error = Apartment::TenantNotFound.new('missing')
    expect(error.message).to(eq("Tenant 'missing' not found"))
    expect(error.tenant).to(eq('missing'))
    expect(error).to(be_a(Apartment::ApartmentError))
  end
end
