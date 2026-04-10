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
      klass = Class.new(ActiveRecord::Base) do
        include Apartment::Model
      end
      stub_const('LateLoadedModel', klass)

      expect(Apartment).to(receive(:activated?).and_return(true))
      expect(Apartment).to(receive(:process_pinned_model).with(LateLoadedModel))

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

  describe '.apartment_explicit_table_name?' do
    it 'returns false when @table_name is not set' do
      klass = Class.new(ActiveRecord::Base) { include Apartment::Model }
      stub_const('NoTableName', klass)
      expect(klass.apartment_explicit_table_name?).to(be(false))
    end

    it 'returns false when cached equals computed (convention naming)' do
      klass = Class.new(ActiveRecord::Base) { include Apartment::Model }
      stub_const('ConventionModel', klass)
      allow(klass).to(receive(:compute_table_name).and_return('convention_models'))
      klass.instance_variable_set(:@table_name, 'convention_models')
      expect(klass.apartment_explicit_table_name?).to(be(false))
    end

    it 'returns true when cached differs from computed (explicit assignment)' do
      klass = Class.new(ActiveRecord::Base) { include Apartment::Model }
      stub_const('ExplicitModel', klass)
      allow(klass).to(receive(:compute_table_name).and_return('explicit_models'))
      klass.instance_variable_set(:@table_name, 'custom_table')
      expect(klass.apartment_explicit_table_name?).to(be(true))
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

  describe '.apartment_pinned_processed?' do
    it 'returns false before processing' do
      klass = Class.new(ActiveRecord::Base) { include Apartment::Model }
      expect(klass.apartment_pinned_processed?).to(be(false))
    end

    it 'returns true after apartment_mark_processed!' do
      klass = Class.new(ActiveRecord::Base) { include Apartment::Model }
      klass.apartment_mark_processed!
      expect(klass.apartment_pinned_processed?).to(be(true))
    end
  end

  describe '.apartment_mark_processed!' do
    it 'records convention path with original prefix' do
      klass = Class.new(ActiveRecord::Base) { include Apartment::Model }
      klass.apartment_mark_processed!(:convention, 'myapp_')

      expect(klass.apartment_pinned_processed?).to(be(true))
    end

    it 'records explicit path with original table name' do
      klass = Class.new(ActiveRecord::Base) { include Apartment::Model }
      klass.apartment_mark_processed!(:explicit, 'custom_jobs')

      expect(klass.apartment_pinned_processed?).to(be(true))
    end

    it 'records nil path for separate-pool models' do
      klass = Class.new(ActiveRecord::Base) { include Apartment::Model }
      klass.apartment_mark_processed!

      expect(klass.apartment_pinned_processed?).to(be(true))
    end
  end

  describe '.apartment_restore!' do
    it 'restores convention-path prefix and resets table name' do
      klass = Class.new(ActiveRecord::Base) { include Apartment::Model }
      stub_const('ConventionRestore', klass)
      allow(klass).to(receive(:table_name_prefix=))
      allow(klass).to(receive(:reset_table_name))

      klass.apartment_mark_processed!(:convention, 'myapp_')
      klass.apartment_restore!

      expect(klass).to(have_received(:table_name_prefix=).with('myapp_'))
      expect(klass).to(have_received(:reset_table_name))
      expect(klass.apartment_pinned_processed?).to(be(false))
    end

    it 'restores explicit-path original table name' do
      klass = Class.new(ActiveRecord::Base) { include Apartment::Model }
      stub_const('ExplicitRestore', klass)
      allow(klass).to(receive(:table_name=))

      klass.apartment_mark_processed!(:explicit, 'custom_jobs')
      klass.apartment_restore!

      expect(klass).to(have_received(:table_name=).with('custom_jobs'))
      expect(klass.apartment_pinned_processed?).to(be(false))
    end

    it 'is a no-op for separate-pool path' do
      klass = Class.new(ActiveRecord::Base) { include Apartment::Model }
      stub_const('SeparateRestore', klass)

      klass.apartment_mark_processed!
      expect { klass.apartment_restore! }.not_to(raise_error)
      expect(klass.apartment_pinned_processed?).to(be(false))
    end

    it 'is a no-op when not processed' do
      klass = Class.new(ActiveRecord::Base) { include Apartment::Model }
      expect { klass.apartment_restore! }.not_to(raise_error)
    end
  end
end
