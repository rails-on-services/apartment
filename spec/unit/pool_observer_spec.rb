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

  describe '#subscribe! / .install!' do
    subject(:observer) { described_class.install!(sink: sink) }

    after { observer.stop! }

    it 'forwards a subscribed event to the sink as a counter Sample' do
      observer
      Apartment::Instrumentation.instrument(:evict, tenant: 'acme', reason: :idle)

      sample = samples.find { |s| s.name == :evict }
      expect(sample).not_to(be_nil)
      expect(sample).to(have_attributes(kind: :counter, value: 1, dimensions: { reason: :idle }))
      expect(sample.payload).to(include(tenant: 'acme', reason: :idle))
    end

    it 'curates :reason into dimensions and leaves the rest in payload' do
      observer
      Apartment::Instrumentation.instrument(:cap_unmet, max_total: 5, current: 6, unevicted: 1)

      sample = samples.find { |s| s.name == :cap_unmet }
      expect(sample.dimensions).to(eq({}))
      expect(sample.payload).to(include(max_total: 5, current: 6, unevicted: 1))
    end

    it 'subscribes to all pool-lifecycle counter events' do
      observer
      %i[create evict cap_unmet skip_evict reaper_stopped].each do |event|
        Apartment::Instrumentation.instrument(event, {})
      end
      expect(samples.map(&:name)).to(include(:create, :evict, :cap_unmet, :skip_evict, :reaper_stopped))
    end
  end
end
