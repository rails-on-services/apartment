# frozen_string_literal: true

# spec/shared_examples/core_adapter_examples.rb

# Purpose: This file defines the core contract that all Apartment adapters must fulfill,
# regardless of their underlying storage mechanism (schemas, databases, etc).
#
# Coverage includes:
# - Basic CRUD operations (create/switch/drop/reset)
# - Tenant switching (immediate and block-style)
# - Multi-tenant iteration
# - Model exclusion
# - Configuration and initialization
# - Environmental tenant naming
#
# Any new adapter must pass all these tests to be considered a valid Apartment adapter.

require 'spec_helper'

# Main example group that all adapters should include
shared_examples 'a basic apartment adapter' do
  it_behaves_like 'a tenant creator'
  it_behaves_like 'a tenant switcher'
  it_behaves_like 'a tenant dropper'
  it_behaves_like 'a tenant resetter'
  it_behaves_like 'supports block switching'
  it_behaves_like 'supports multi-tenant iteration'
  it_behaves_like 'handles excluded models'
  it_behaves_like 'handles tenant configuration'
end

# Tests the basic create operation all adapters must support
shared_examples 'a tenant creator' do
  include_context 'with adapter setup'

  describe '#create' do
    before { adapter.create(tenant_name) }

    it 'creates a new tenant' do
      expect(tenant_exists?(tenant_name)).to(be(true))
    end

    it 'loads schema.rb to new tenant' do
      in_tenant(tenant_name) do
        expect(connection.tables).to(include('users'))
      end
    end

    it 'raises error if tenant exists' do
      expect { adapter.create(tenant_name) }.to(raise_error(Apartment::TenantExists))
    end
  end
end

# Tests tenant switching behavior all adapters must implement
shared_examples 'a tenant switcher' do
  include_context 'with adapter setup'

  describe '#switch!' do
    before { adapter.create(tenant_name) }

    it 'switches to the specified tenant' do
      adapter.switch!(tenant_name)
      expect(adapter.current).to(eq(tenant_name))
    end

    it 'raises error for invalid tenant' do
      expect { adapter.switch!('invalid_tenant') }
        .to(raise_error(Apartment::TenantNotFound))
    end

    context 'when tenant_presence_check is disabled' do
      before { Apartment.tenant_presence_check = false }
      after { Apartment.tenant_presence_check = true }

      it 'does not raise error for invalid tenant' do
        expect { adapter.switch!('invalid_tenant') }.not_to(raise_error)
      end
    end

    it 'resets to default tenant when nil' do
      adapter.switch!(tenant_name)
      adapter.switch!(nil)
      expect(adapter.current).to(eq(default_tenant))
    end
  end
end

# Tests tenant removal capabilities
shared_examples 'a tenant dropper' do
  include_context 'with adapter setup'

  describe '#drop' do
    before { adapter.create(tenant_name) }

    it 'removes the tenant' do
      adapter.drop(tenant_name)
      expect(tenant_exists?(tenant_name)).to(be(false))
    end

    it 'raises error for unknown tenant' do
      expect { adapter.drop('unknown_tenant') }
        .to(raise_error(Apartment::TenantNotFound))
    end
  end
end

# Tests the adapter's ability to reset to default state
shared_examples 'a tenant resetter' do
  include_context 'with adapter setup'

  describe '#reset' do
    before do
      adapter.create(tenant_name)
      adapter.switch!(tenant_name)
    end

    it 'resets connection to default tenant' do
      adapter.reset
      expect(adapter.current).to(eq(default_tenant))
    end
  end
end

# Tests block-style tenant switching
shared_examples 'supports block switching' do
  include_context 'with adapter setup'

  describe '#switch' do
    before { adapter.create(tenant_name) }

    it 'switches tenant within block and restores previous tenant' do
      original_tenant = adapter.current

      in_tenant(tenant_name) do
        expect(adapter.current).to(eq(tenant_name))
      end

      expect(adapter.current).to(eq(original_tenant))
    end

    it 'resets if block raises error' do
      original_tenant = adapter.current

      expect { in_tenant(tenant_name) { raise(StandardError) } }
        .to(raise_error(StandardError))

      expect(adapter.current).to(eq(original_tenant))
    end

    it 'resets if tenant is dropped within block' do
      in_tenant(tenant_name) do
        adapter.drop(tenant_name)
      end

      expect(adapter.current).to(eq(default_tenant))
    end
  end
end

# Tests the ability to iterate over multiple tenants
shared_examples 'supports multi-tenant iteration' do
  include_context 'with adapter setup'

  describe '#each' do
    before do
      adapter.create(tenant_name)
      adapter.create(another_tenant)
    end

    it 'iterates over all tenants' do
      visited = []
      adapter.each do |tenant|
        visited << tenant
        expect(adapter.current).to(eq(tenant))
      end

      expect(visited).to(contain_exactly(tenant_name, another_tenant))
    end

    it 'iterates over specified tenants' do
      visited = []
      adapter.each([tenant_name]) do |tenant|
        visited << tenant
        expect(adapter.current).to(eq(tenant))
      end

      expect(visited).to(contain_exactly(tenant_name))
    end
  end
end

# Tests handling of excluded models across tenants
shared_examples 'handles excluded models' do |model_class: Company|
  include_context 'with adapter setup'

  before do
    Apartment.configure do |config|
      config.excluded_models = [model_class.name]
    end
    adapter.create(tenant_name)

    # Create records in both tenants
    adapter.switch(nil) do
      model_class.create!(name: 'default')
    end
    adapter.switch(tenant_name) do
      model_class.create!(name: tenant_name)
    end
  end

  context 'when in default tenant' do
    before { adapter.switch!(nil) }

    it 'finds records from all tenants' do
      expect(model_class.pluck(:name)).to(contain_exactly('default', tenant_name))
    end
  end

  context 'when in specific tenant' do
    before { adapter.switch!(tenant_name) }

    it 'still finds records from all tenants' do
      expect(model_class.pluck(:name)).to(contain_exactly('default', tenant_name))
    end
  end
end

# Tests tenant environmental configuration
shared_examples 'handles tenant configuration' do
  include_context 'with adapter setup'

  describe 'environmental configuration' do
    before do
      Apartment.configure do |config|
        config.prepend_environment = true
        config.append_environment = false
      end
    end

    after do
      Apartment.configure do |config|
        config.prepend_environment = false
        config.append_environment = false
      end
    end

    it 'handles environment-based tenant names' do
      prefixed_name = "#{Rails.env}_#{tenant_name}"
      adapter.create(tenant_name)

      expect(tenant_exists?(prefixed_name)).to(be(true))
      expect(tenant_exists?(tenant_name)).to(be(false))
    end
  end

  describe 'initialization' do
    it 'respects APARTMENT_DISABLE_INIT setting' do
      ENV['APARTMENT_DISABLE_INIT'] = 'true'
      begin
        ActiveRecord::Base.connection_pool.disconnect!
        Apartment::Railtie.config.to_prepare_blocks.map(&:call)

        num_available_connections = Apartment.connection_class.connection_pool
          .instance_variable_get(:@available)
          .instance_variable_get(:@queue)
          .size

        expect(num_available_connections).to(eq(0))
      ensure
        ENV.delete('APARTMENT_DISABLE_INIT')
      end
    end
  end

  describe 'tenant naming' do
    it 'allows setting tenant_names via array' do
      names = %w[tenant1 tenant2]
      Apartment.tenant_names = names
      expect(Apartment.tenant_names).to(eq(names))
    end

    it 'allows setting tenant_names via proc' do
      names = -> { %w[tenant1 tenant2] }
      Apartment.tenant_names = names
      expect(Apartment.tenant_names).to(eq(names.call))
    end
  end
end
