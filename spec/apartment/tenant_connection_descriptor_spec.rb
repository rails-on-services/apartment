# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apartment::ConnectionAdapters::ConnectionHandler::TenantConnectionDescriptor do
  let(:connection_class) { Apartment.connection_class }
  let(:tenant_name) { 'test_tenant' }
  let(:descriptor) { described_class.new(connection_class, tenant_name) }

  before(:all) do
    Apartment.configure do |config|
      config.default_tenant = 'public'
      config.tenant_strategy = :schema
      config.tenants_provider = -> { %w[tenant1 tenant2 test_tenant] }
    end
  end

  before { Apartment::Tenant.reset }

  describe 'initialization' do
    it 'stores connection class and tenant name' do
      expect(descriptor.connection_class).to eq(connection_class)
      expect(descriptor.tenant_name).to eq(tenant_name)
    end

    it 'accepts string tenant names' do
      string_descriptor = described_class.new(connection_class, 'string_tenant')
      expect(string_descriptor.tenant_name).to eq('string_tenant')
    end

    it 'accepts symbol tenant names' do
      symbol_descriptor = described_class.new(connection_class, :symbol_tenant)
      expect(symbol_descriptor.tenant_name).to eq('symbol_tenant')
    end
  end

  describe '#name' do
    it 'generates unique name for connection class and tenant' do
      expected_name = "#{connection_class.name}[#{tenant_name}]"
      expect(descriptor.name).to eq(expected_name)
    end

    it 'generates different names for different tenants' do
      descriptor1 = described_class.new(connection_class, 'tenant1')
      descriptor2 = described_class.new(connection_class, 'tenant2')

      expect(descriptor1.name).not_to eq(descriptor2.name)
      expect(descriptor1.name).to include('tenant1')
      expect(descriptor2.name).to include('tenant2')
    end

    it 'generates different names for different connection classes' do
      custom_class = Class.new(ActiveRecord::Base)
      stub_const('CustomActiveRecord', custom_class)

      descriptor1 = described_class.new(connection_class, tenant_name)
      descriptor2 = described_class.new(custom_class, tenant_name)

      expect(descriptor1.name).not_to eq(descriptor2.name)
    end
  end

  describe '#to_s' do
    it 'returns the same as name' do
      expect(descriptor.to_s).to eq(descriptor.name)
    end
  end

  describe '#hash' do
    it 'generates consistent hash for same class and tenant' do
      descriptor1 = described_class.new(connection_class, tenant_name)
      descriptor2 = described_class.new(connection_class, tenant_name)

      expect(descriptor1.hash).to eq(descriptor2.hash)
    end

    it 'generates different hashes for different tenants' do
      descriptor1 = described_class.new(connection_class, 'tenant1')
      descriptor2 = described_class.new(connection_class, 'tenant2')

      expect(descriptor1.hash).not_to eq(descriptor2.hash)
    end

    it 'generates different hashes for different connection classes' do
      custom_class = Class.new(ActiveRecord::Base)

      descriptor1 = described_class.new(connection_class, tenant_name)
      descriptor2 = described_class.new(custom_class, tenant_name)

      expect(descriptor1.hash).not_to eq(descriptor2.hash)
    end
  end

  describe '#eql?' do
    it 'returns true for same class and tenant' do
      descriptor1 = described_class.new(connection_class, tenant_name)
      descriptor2 = described_class.new(connection_class, tenant_name)

      expect(descriptor1.eql?(descriptor2)).to be true
      expect(descriptor1 == descriptor2).to be true
    end

    it 'returns false for different tenants' do
      descriptor1 = described_class.new(connection_class, 'tenant1')
      descriptor2 = described_class.new(connection_class, 'tenant2')

      expect(descriptor1.eql?(descriptor2)).to be false
      expect(descriptor1 == descriptor2).to be false
    end

    it 'returns false for different connection classes' do
      custom_class = Class.new(ActiveRecord::Base)

      descriptor1 = described_class.new(connection_class, tenant_name)
      descriptor2 = described_class.new(custom_class, tenant_name)

      expect(descriptor1.eql?(descriptor2)).to be false
      expect(descriptor1 == descriptor2).to be false
    end

    it 'returns false for different object types' do
      expect(descriptor.eql?('string')).to be false
      expect(descriptor.eql?(123)).to be false
      expect(descriptor.eql?(nil)).to be false
    end
  end

  describe 'usage as hash key' do
    it 'works as hash key' do
      hash = {}

      descriptor1 = described_class.new(connection_class, 'tenant1')
      descriptor2 = described_class.new(connection_class, 'tenant2')
      descriptor3 = described_class.new(connection_class, 'tenant1') # Same as descriptor1

      hash[descriptor1] = 'value1'
      hash[descriptor2] = 'value2'
      hash[descriptor3] = 'value3' # Should overwrite descriptor1

      expect(hash.size).to eq(2)
      expect(hash[descriptor1]).to eq('value3')
      expect(hash[descriptor2]).to eq('value2')
    end

    it 'maintains consistent behavior in sets' do
      set = Set.new

      descriptor1 = described_class.new(connection_class, 'tenant1')
      descriptor2 = described_class.new(connection_class, 'tenant2')
      descriptor3 = described_class.new(connection_class, 'tenant1') # Same as descriptor1

      set << descriptor1
      set << descriptor2
      set << descriptor3

      expect(set.size).to eq(2)
      expect(set).to include(descriptor1)
      expect(set).to include(descriptor2)
    end
  end

  describe 'edge cases' do
    it 'handles nil tenant name' do
      nil_descriptor = described_class.new(connection_class, nil)
      expect(nil_descriptor.tenant_name).to eq('')
      expect(nil_descriptor.name).to eq("#{connection_class.name}[]")
    end

    it 'handles empty string tenant name' do
      empty_descriptor = described_class.new(connection_class, '')
      expect(empty_descriptor.tenant_name).to eq('')
      expect(empty_descriptor.name).to eq("#{connection_class.name}[]")
    end

    it 'handles tenant names with special characters' do
      special_tenant = 'tenant-with_special.chars'
      special_descriptor = described_class.new(connection_class, special_tenant)

      expect(special_descriptor.tenant_name).to eq(special_tenant)
      expect(special_descriptor.name).to include(special_tenant)
    end

    it 'handles very long tenant names' do
      long_tenant = 'a' * 1000
      long_descriptor = described_class.new(connection_class, long_tenant)

      expect(long_descriptor.tenant_name).to eq(long_tenant)
      expect(long_descriptor.name).to include(long_tenant)
    end
  end

  describe 'immutability' do
    it 'does not allow modification of connection_class' do
      expect { descriptor.connection_class = ActiveRecord::Base }.to raise_error(NoMethodError)
    end

    it 'does not allow modification of tenant_name' do
      expect { descriptor.tenant_name = 'new_tenant' }.to raise_error(NoMethodError)
    end
  end

  describe 'integration with Rails connection handling' do
    it 'works with ActiveRecord connection specification patterns' do
      # Simulate how Rails might use the descriptor
      connection_spec_name = descriptor.name

      expect(connection_spec_name).to be_a(String)
      expect(connection_spec_name).to include(connection_class.name)
      expect(connection_spec_name).to include(tenant_name)
    end

    it 'provides unique identifiers for connection pools' do
      descriptors = [
        described_class.new(connection_class, 'tenant1'),
        described_class.new(connection_class, 'tenant2'),
        described_class.new(connection_class, 'tenant3')
      ]

      names = descriptors.map(&:name)
      expect(names.uniq.size).to eq(3)

      hashes = descriptors.map(&:hash)
      expect(hashes.uniq.size).to eq(3)
    end
  end

  describe 'performance characteristics' do
    it 'efficiently computes hash for large numbers of descriptors' do
      start_time = Time.current

      1000.times do |i|
        descriptor = described_class.new(connection_class, "tenant_#{i}")
        descriptor.hash
      end

      end_time = Time.current
      expect(end_time - start_time).to be < 1.0 # Should complete in under 1 second
    end

    it 'efficiently compares large numbers of descriptors' do
      descriptors = 100.times.map do |i|
        described_class.new(connection_class, "tenant_#{i}")
      end

      start_time = Time.current

      # Compare all pairs
      descriptors.each do |desc1|
        descriptors.each do |desc2|
          desc1.eql?(desc2)
        end
      end

      end_time = Time.current
      expect(end_time - start_time).to be < 1.0 # Should complete in under 1 second
    end
  end
end