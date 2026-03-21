# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Apartment::Tenant do
  let(:mock_adapter) { double('Adapter') }

  before do
    Apartment.configure do |config|
      config.tenant_strategy = :schema
      config.tenants_provider = -> { %w[tenant1 tenant2] }
      config.default_tenant = 'public'
    end
    Apartment.adapter = mock_adapter
    Apartment::Current.reset
  end

  describe '.switch' do
    it 'requires a block' do
      expect { described_class.switch('tenant1') }.to raise_error(ArgumentError, /requires a block/)
    end

    it 'sets Current.tenant and Current.previous_tenant within the block' do
      described_class.switch('tenant1') do
        expect(Apartment::Current.tenant).to eq('tenant1')
        expect(Apartment::Current.previous_tenant).to be_nil
      end
    end

    it 'tracks the previous tenant when nested' do
      Apartment::Current.tenant = 'base'

      described_class.switch('tenant1') do
        expect(Apartment::Current.tenant).to eq('tenant1')
        expect(Apartment::Current.previous_tenant).to eq('base')
      end
    end

    it 'restores the previous tenant after the block' do
      Apartment::Current.tenant = 'base'

      described_class.switch('tenant1') { }

      expect(Apartment::Current.tenant).to eq('base')
      expect(Apartment::Current.previous_tenant).to be_nil
    end

    it 'restores the previous tenant on exception' do
      Apartment::Current.tenant = 'base'

      expect {
        described_class.switch('tenant1') { raise 'boom' }
      }.to raise_error(RuntimeError, 'boom')

      expect(Apartment::Current.tenant).to eq('base')
      expect(Apartment::Current.previous_tenant).to be_nil
    end

    it 'supports nesting' do
      described_class.switch('tenant1') do
        described_class.switch('tenant2') do
          expect(Apartment::Current.tenant).to eq('tenant2')
          expect(Apartment::Current.previous_tenant).to eq('tenant1')
        end
        expect(Apartment::Current.tenant).to eq('tenant1')
      end
    end
  end

  describe '.switch!' do
    it 'sets the current tenant without a block' do
      described_class.switch!('tenant1')
      expect(Apartment::Current.tenant).to eq('tenant1')
    end

    it 'sets previous_tenant to the prior tenant' do
      Apartment::Current.tenant = 'base'
      described_class.switch!('tenant1')
      expect(Apartment::Current.previous_tenant).to eq('base')
    end
  end

  describe '.current' do
    it 'returns Current.tenant when set' do
      Apartment::Current.tenant = 'tenant1'
      expect(described_class.current).to eq('tenant1')
    end

    it 'falls back to config.default_tenant when Current.tenant is nil' do
      expect(described_class.current).to eq('public')
    end

    it 'returns nil when no config and no current tenant' do
      Apartment.clear_config
      expect(described_class.current).to be_nil
    end
  end

  describe '.reset' do
    it 'sets tenant to default_tenant' do
      Apartment::Current.tenant = 'tenant1'
      described_class.reset
      expect(Apartment::Current.tenant).to eq('public')
    end

    it 'sets previous_tenant to the prior tenant' do
      Apartment::Current.tenant = 'tenant1'
      described_class.reset
      expect(Apartment::Current.previous_tenant).to eq('tenant1')
    end
  end

  describe '.init' do
    it 'delegates to adapter.process_excluded_models' do
      expect(mock_adapter).to receive(:process_excluded_models)
      described_class.init
    end
  end

  describe '.create' do
    it 'delegates to adapter' do
      expect(mock_adapter).to receive(:create).with('new_tenant')
      described_class.create('new_tenant')
    end
  end

  describe '.drop' do
    it 'delegates to adapter' do
      expect(mock_adapter).to receive(:drop).with('old_tenant')
      described_class.drop('old_tenant')
    end
  end

  describe '.migrate' do
    it 'delegates to adapter with tenant' do
      expect(mock_adapter).to receive(:migrate).with('tenant1', nil)
      described_class.migrate('tenant1')
    end

    it 'delegates to adapter with tenant and version' do
      expect(mock_adapter).to receive(:migrate).with('tenant1', 20_260_101_000_000)
      described_class.migrate('tenant1', 20_260_101_000_000)
    end
  end

  describe '.seed' do
    it 'delegates to adapter' do
      expect(mock_adapter).to receive(:seed).with('tenant1')
      described_class.seed('tenant1')
    end
  end

  describe '.pool_stats' do
    it 'delegates to pool_manager.stats' do
      stats = { total: 2, active: 1 }
      expect(Apartment.pool_manager).to receive(:stats).and_return(stats)
      expect(described_class.pool_stats).to eq(stats)
    end

    it 'returns empty hash when pool_manager is nil' do
      Apartment.clear_config
      expect(described_class.pool_stats).to eq({})
    end
  end
end
