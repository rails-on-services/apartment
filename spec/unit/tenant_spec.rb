# frozen_string_literal: true

require 'spec_helper'

RSpec.describe(Apartment::Tenant) do
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
      expect { described_class.switch('tenant1') }.to(raise_error(ArgumentError, /requires a block/))
    end

    it 'sets Current.tenant and Current.previous_tenant within the block' do
      described_class.switch('tenant1') do
        expect(Apartment::Current.tenant).to(eq('tenant1'))
        expect(Apartment::Current.previous_tenant).to(be_nil)
      end
    end

    it 'tracks the previous tenant when nested' do
      Apartment::Current.tenant = 'base'

      described_class.switch('tenant1') do
        expect(Apartment::Current.tenant).to(eq('tenant1'))
        expect(Apartment::Current.previous_tenant).to(eq('base'))
      end
    end

    it 'restores the previous tenant after the block' do
      Apartment::Current.tenant = 'base'

      described_class.switch('tenant1') {}

      expect(Apartment::Current.tenant).to(eq('base'))
      expect(Apartment::Current.previous_tenant).to(be_nil)
    end

    it 'restores the previous tenant on exception' do
      Apartment::Current.tenant = 'base'

      expect do
        described_class.switch('tenant1') { raise('boom') }
      end.to(raise_error(RuntimeError, 'boom'))

      expect(Apartment::Current.tenant).to(eq('base'))
      expect(Apartment::Current.previous_tenant).to(be_nil)
    end

    it 'supports nesting' do
      described_class.switch('tenant1') do
        described_class.switch('tenant2') do
          expect(Apartment::Current.tenant).to(eq('tenant2'))
          expect(Apartment::Current.previous_tenant).to(eq('tenant1'))
        end
        expect(Apartment::Current.tenant).to(eq('tenant1'))
      end
    end
  end

  describe '.switch!' do
    it 'sets the current tenant without a block' do
      described_class.switch!('tenant1')
      expect(Apartment::Current.tenant).to(eq('tenant1'))
    end

    it 'sets previous_tenant to the prior tenant' do
      Apartment::Current.tenant = 'base'
      described_class.switch!('tenant1')
      expect(Apartment::Current.previous_tenant).to(eq('base'))
    end
  end

  describe '.current' do
    it 'returns Current.tenant when set' do
      Apartment::Current.tenant = 'tenant1'
      expect(described_class.current).to(eq('tenant1'))
    end

    it 'falls back to config.default_tenant when Current.tenant is nil' do
      expect(described_class.current).to(eq('public'))
    end

    it 'returns nil when no config and no current tenant' do
      Apartment.clear_config
      expect(described_class.current).to(be_nil)
    end
  end

  describe '.reset' do
    it 'sets tenant to default_tenant' do
      Apartment::Current.tenant = 'tenant1'
      described_class.reset
      expect(Apartment::Current.tenant).to(eq('public'))
    end

    it 'sets previous_tenant to the prior tenant' do
      Apartment::Current.tenant = 'tenant1'
      described_class.reset
      expect(Apartment::Current.previous_tenant).to(eq('tenant1'))
    end
  end

  describe '.init' do
    it 'delegates to adapter.process_pinned_models' do
      expect(mock_adapter).to(receive(:process_pinned_models))
      described_class.init
    end

    context 'resolve_excluded_models_shim' do
      it 'resolves excluded model strings and registers them as pinned' do
        model_class = Class.new
        stub_const('ShimTestModel', model_class)

        Apartment.configure do |config|
          config.tenant_strategy = :schema
          config.tenants_provider = -> { [] }
          config.default_tenant = 'public'
          config.excluded_models = ['ShimTestModel']
        end

        allow(mock_adapter).to(receive(:process_pinned_models))
        Apartment.adapter = mock_adapter

        described_class.init

        expect(Apartment.pinned_models).to(include(ShimTestModel))
      end

      it 'raises ConfigurationError for unresolvable model names' do
        Apartment.configure do |config|
          config.tenant_strategy = :schema
          config.tenants_provider = -> { [] }
          config.default_tenant = 'public'
          config.excluded_models = ['NonExistentModel']
        end

        allow(mock_adapter).to(receive(:process_pinned_models))
        Apartment.adapter = mock_adapter

        expect { described_class.init }.to(raise_error(
                                             Apartment::ConfigurationError,
                                             /Excluded model 'NonExistentModel' could not be resolved/
                                           ))
      end

      it 'skips models already in pinned_models registry (via pin_tenant)' do
        require 'apartment/concerns/model'
        model_class = Class.new do
          include Apartment::Model
        end
        stub_const('AlreadyPinnedModel', model_class)
        AlreadyPinnedModel.pin_tenant

        Apartment.configure do |config|
          config.tenant_strategy = :schema
          config.tenants_provider = -> { [] }
          config.default_tenant = 'public'
          config.excluded_models = ['AlreadyPinnedModel']
        end

        allow(mock_adapter).to(receive(:process_pinned_models))
        Apartment.adapter = mock_adapter

        # Already in registry via pin_tenant — should not double-register
        count_before = Apartment.pinned_models.size
        described_class.init
        expect(Apartment.pinned_models.size).to(eq(count_before))
      end
    end
  end

  describe '.each' do
    it 'requires a block' do
      expect { described_class.each }.to(raise_error(ArgumentError, /requires a block/))
    end

    it 'iterates over all tenants from tenants_provider' do
      visited = []
      described_class.each { |t| visited << t } # rubocop:disable Style/MapIntoArray
      expect(visited).to(eq(%w[tenant1 tenant2]))
    end

    it 'switches into each tenant for the duration of the block' do
      tenants_seen = []
      described_class.each { |_t| tenants_seen << Apartment::Current.tenant } # rubocop:disable Style/MapIntoArray
      expect(tenants_seen).to(eq(%w[tenant1 tenant2]))
    end

    it 'restores tenant context after iteration' do
      Apartment::Current.tenant = 'original'
      described_class.each { |_t| }
      expect(Apartment::Current.tenant).to(eq('original'))
    end

    it 'accepts a custom tenant list' do
      visited = []
      described_class.each(%w[custom1 custom2]) { |t| visited << t }
      expect(visited).to(eq(%w[custom1 custom2]))
    end

    it 'propagates exceptions from the block' do
      expect do
        described_class.each { raise('boom') } # rubocop:disable Lint/UnreachableLoop
      end.to(raise_error(RuntimeError, 'boom'))
    end

    it 'restores tenant context after an exception' do
      Apartment::Current.tenant = 'original'
      begin
        described_class.each { raise('boom') } # rubocop:disable Lint/UnreachableLoop
      rescue RuntimeError
        nil
      end
      expect(Apartment::Current.tenant).to(eq('original'))
    end
  end

  describe '.create' do
    it 'delegates to adapter' do
      expect(mock_adapter).to(receive(:create).with('new_tenant'))
      described_class.create('new_tenant')
    end
  end

  describe '.drop' do
    it 'delegates to adapter' do
      expect(mock_adapter).to(receive(:drop).with('old_tenant'))
      described_class.drop('old_tenant')
    end
  end

  describe '.migrate' do
    it 'delegates to adapter with tenant' do
      expect(mock_adapter).to(receive(:migrate).with('tenant1', nil))
      described_class.migrate('tenant1')
    end

    it 'delegates to adapter with tenant and version' do
      expect(mock_adapter).to(receive(:migrate).with('tenant1', 20_260_101_000_000))
      described_class.migrate('tenant1', 20_260_101_000_000)
    end
  end

  describe '.seed' do
    it 'delegates to adapter' do
      expect(mock_adapter).to(receive(:seed).with('tenant1'))
      described_class.seed('tenant1')
    end
  end

  describe 'adapter guard' do
    it 'raises ConfigurationError when adapter is not configured' do
      Apartment.clear_config
      expect { described_class.create('tenant1') }.to(raise_error(
                                                        Apartment::ConfigurationError, /not configured/
                                                      ))
    end
  end

  describe '.pool_stats' do
    it 'delegates to pool_manager.stats' do
      stats = { total: 2, active: 1 }
      allow(Apartment.pool_manager).to(receive(:stats).and_return(stats))
      expect(described_class.pool_stats).to(eq(stats))
    end

    it 'returns empty hash when pool_manager is nil' do
      Apartment.clear_config
      expect(described_class.pool_stats).to(eq({}))
    end
  end
end
