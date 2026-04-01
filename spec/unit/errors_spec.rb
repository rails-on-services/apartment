# frozen_string_literal: true

require 'spec_helper'

RSpec.describe('Apartment error hierarchy') do
  it 'defines ApartmentError as a StandardError' do
    expect(Apartment::ApartmentError).to(be < StandardError)
  end

  %i[TenantNotFound TenantExists AdapterNotFound ConfigurationError PoolExhausted SchemaLoadError PendingMigrationError].each do |klass|
    it "defines #{klass} as a subclass of ApartmentError" do
      expect(Apartment.const_get(klass)).to(be < Apartment::ApartmentError)
    end
  end

  describe Apartment::TenantNotFound do
    it 'includes the tenant name in the message when provided' do
      error = described_class.new('acme')
      expect(error.message).to(eq("Tenant 'acme' not found"))
    end

    it 'exposes the tenant name via attr_reader' do
      error = described_class.new('acme')
      expect(error.tenant).to(eq('acme'))
    end

    it 'uses a generic message when no tenant name is provided' do
      error = described_class.new
      expect(error.message).to(eq('Tenant not found'))
      expect(error.tenant).to(be_nil)
    end
  end

  describe Apartment::TenantExists do
    it 'includes the tenant name in the message when provided' do
      error = described_class.new('acme')
      expect(error.message).to(eq("Tenant 'acme' already exists"))
    end

    it 'exposes the tenant name via attr_reader' do
      error = described_class.new('acme')
      expect(error.tenant).to(eq('acme'))
    end

    it 'uses a generic message when no tenant name is provided' do
      error = described_class.new
      expect(error.message).to(eq('Tenant already exists'))
      expect(error.tenant).to(be_nil)
    end
  end

  describe Apartment::PendingMigrationError do
    it 'is a subclass of ApartmentError' do
      expect(described_class).to(be < Apartment::ApartmentError)
    end

    it 'includes the tenant name in the message when provided' do
      error = described_class.new('acme')
      expect(error.message).to(include("Tenant 'acme'"))
      expect(error.message).to(include('pending migrations'))
    end

    it 'includes apartment:migrate instruction in the message' do
      error = described_class.new('acme')
      expect(error.message).to(include('apartment:migrate'))
    end

    it 'exposes the tenant name via attr_reader' do
      error = described_class.new('acme')
      expect(error.tenant).to(eq('acme'))
    end

    it 'uses a generic message when no tenant name is provided' do
      error = described_class.new
      expect(error.message).to(eq('Tenant has pending migrations. Run apartment:migrate to update.'))
      expect(error.tenant).to(be_nil)
    end
  end
end
