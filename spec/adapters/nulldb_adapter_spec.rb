# frozen_string_literal: true

require 'spec_helper'
require 'apartment/adapters/nulldb_adapter'

describe Apartment::Adapters::NullDBAdapter do
  describe '#neither' do
    it 'should create' do
      adapter = Apartment::Adapters::NullDBAdapter.new({})
      expect(adapter.present?).to eq true
    end

    it 'should ignore init' do
      adapter = Apartment::Adapters::NullDBAdapter.new({})
      adapter.init
    end
  end
end
