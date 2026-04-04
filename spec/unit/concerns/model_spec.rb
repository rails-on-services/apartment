# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../lib/apartment/concerns/model'

RSpec.describe(Apartment::Model) do
  before do
    Apartment.configure do |c|
      c.tenant_strategy = :schema
      c.tenants_provider = -> { [] }
      c.default_tenant = 'public'
    end
  end

  after do
    Apartment.clear_config
  end

  describe '.pin_tenant' do
    it 'registers the model in Apartment.pinned_models' do
      klass = Class.new(ActiveRecord::Base) do
        include Apartment::Model
      end
      stub_const('PinnedTestModel', klass)

      klass.pin_tenant

      expect(Apartment.pinned_models).to(include(PinnedTestModel))
    end

    it 'is idempotent — second call is a no-op' do
      klass = Class.new(ActiveRecord::Base) do
        include Apartment::Model
      end
      stub_const('IdempotentModel', klass)

      klass.pin_tenant
      klass.pin_tenant

      expect(Apartment.pinned_models.count { |m| m == IdempotentModel }).to(eq(1))
    end

    it 'processes immediately when Apartment is already activated' do
      expect(Apartment).to(receive(:activated?).and_return(true))
      expect(Apartment).to(receive(:process_pinned_model))

      klass = Class.new(ActiveRecord::Base) do
        include Apartment::Model
      end
      stub_const('LateLoadedModel', klass)

      klass.pin_tenant
    end

    it 'defers processing when Apartment is not yet activated' do
      expect(Apartment).to(receive(:activated?).and_return(false))
      expect(Apartment).not_to(receive(:process_pinned_model))

      klass = Class.new(ActiveRecord::Base) do
        include Apartment::Model
      end
      stub_const('EarlyModel', klass)

      klass.pin_tenant
    end
  end

  describe '.apartment_pinned?' do
    it 'returns false for unpinned models' do
      klass = Class.new(ActiveRecord::Base) do
        include Apartment::Model
      end

      expect(klass.apartment_pinned?).to(be(false))
    end

    it 'returns true after pin_tenant' do
      klass = Class.new(ActiveRecord::Base) do
        include Apartment::Model
      end
      stub_const('PinnedCheck', klass)

      klass.pin_tenant
      expect(klass.apartment_pinned?).to(be(true))
    end

    it 'returns true for subclass of pinned model (STI)' do
      parent = Class.new(ActiveRecord::Base) do
        include Apartment::Model
      end
      stub_const('PinnedParent', parent)
      parent.pin_tenant

      child = Class.new(parent)
      stub_const('PinnedChild', child)

      expect(child.apartment_pinned?).to(be(true))
    end

    it 'returns false for classes without the concern' do
      klass = Class.new(ActiveRecord::Base)

      expect(klass.respond_to?(:apartment_pinned?)).to(be(false))
    end
  end
end
