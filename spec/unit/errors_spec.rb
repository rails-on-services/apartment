# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Apartment error hierarchy' do
  it 'defines ApartmentError as a StandardError' do
    expect(Apartment::ApartmentError).to be < StandardError
  end

  %i[TenantNotFound TenantExists AdapterNotFound ConfigurationError PoolExhausted SchemaLoadError].each do |klass|
    it "defines #{klass} as a subclass of ApartmentError" do
      expect(Apartment.const_get(klass)).to be < Apartment::ApartmentError
    end
  end

  describe Apartment::TenantNotFound do
    it 'includes the tenant name in the message when provided' do
      error = Apartment::TenantNotFound.new('acme')
      expect(error.message).to eq("Tenant 'acme' not found")
    end

    it 'uses a generic message when no tenant name is provided' do
      error = Apartment::TenantNotFound.new
      expect(error.message).to eq('Tenant not found')
    end
  end

  describe Apartment::TenantExists do
    it 'includes the tenant name in the message when provided' do
      error = Apartment::TenantExists.new('acme')
      expect(error.message).to eq("Tenant 'acme' already exists")
    end

    it 'uses a generic message when no tenant name is provided' do
      error = Apartment::TenantExists.new
      expect(error.message).to eq('Tenant already exists')
    end
  end
end
