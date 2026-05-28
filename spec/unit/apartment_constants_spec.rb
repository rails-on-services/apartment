# frozen_string_literal: true

require 'spec_helper'

RSpec.describe(Apartment) do
  describe 'ENV_TENANT_KEY' do
    it 'is the canonical Rack env key for cross-thread tenant lookup' do
      expect(Apartment::ENV_TENANT_KEY).to(eq('apartment.tenant'))
    end

    it 'is frozen' do
      expect(Apartment::ENV_TENANT_KEY).to(be_frozen)
    end
  end
end
