# frozen_string_literal: true

require 'spec_helper'

RSpec.describe(Apartment::PoolObserver) do
  let(:samples) { Concurrent::Array.new }
  let(:sink) { ->(sample) { samples << sample } }

  describe '.new' do
    it 'raises ArgumentError when the sink is not callable' do
      expect { described_class.new(sink: 'not callable') }
        .to(raise_error(ArgumentError, /sink must be callable/))
    end

    it 'accepts a callable sink' do
      expect { described_class.new(sink: sink) }.not_to(raise_error)
    end
  end

  describe 'Sample' do
    it 'is a value object with the documented fields' do
      sample = described_class::Sample.new(
        name: :evict, kind: :counter, value: 1, dimensions: { reason: :idle }, payload: { tenant: 'acme' }
      )
      expect(sample).to(have_attributes(name: :evict, kind: :counter, value: 1,
                                        dimensions: { reason: :idle }, payload: { tenant: 'acme' }))
    end
  end
end
