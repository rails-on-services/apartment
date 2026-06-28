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

  describe '#sample!' do
    let(:stub_manager) { instance_double(Apartment::PoolManager, stats: { total_pools: 3, tenants: [] }) }

    before { allow(Apartment).to(receive(:pool_manager).and_return(stub_manager)) }

    it 'emits a tenant_pools_live gauge from PoolManager#stats' do
      observer = described_class.new(sink: sink)
      observer.sample!

      sample = samples.find { |s| s.name == :tenant_pools_live }
      expect(sample).to(have_attributes(kind: :gauge, value: 3, dimensions: {}, payload: {}))
    end

    it 'emits backend_connections when a backend_count callable is supplied' do
      observer = described_class.new(sink: sink, backend_count: -> { 42 })
      observer.sample!

      sample = samples.find { |s| s.name == :backend_connections }
      expect(sample).to(have_attributes(kind: :gauge, value: 42))
    end

    it 'skips backend_connections when backend_count returns nil' do
      observer = described_class.new(sink: sink, backend_count: -> {})
      observer.sample!

      expect(samples.map(&:name)).not_to(include(:backend_connections))
    end

    it 'reports zero pools when the manager is absent (unconfigured)' do
      allow(Apartment).to(receive(:pool_manager).and_return(nil))
      observer = described_class.new(sink: sink)
      observer.sample!

      expect(samples.find { |s| s.name == :tenant_pools_live }.value).to(eq(0))
    end
  end

  describe '#start_sampler! / #stop!' do
    let(:stub_manager) { instance_double(Apartment::PoolManager, stats: { total_pools: 2, tenants: [] }) }

    before { allow(Apartment).to(receive(:pool_manager).and_return(stub_manager)) }

    it 'runs sample! on the configured interval' do
      observer = described_class.new(sink: sink)
      observer.start_sampler!(interval: 0.05)
      sleep 0.15
      observer.stop!

      expect(samples.any? { |s| s.name == :tenant_pools_live }).to(be(true))
    end

    it 'stop! unsubscribes so later events no longer reach the sink' do
      observer = described_class.install!(sink: sink)
      observer.stop!
      samples.clear

      Apartment::Instrumentation.instrument(:evict, {})
      expect(samples).to(be_empty)
    end

    it 'stop! halts the sampler' do
      observer = described_class.new(sink: sink)
      observer.start_sampler!(interval: 0.05)
      observer.stop!
      sleep 0.1
      count = samples.size
      sleep 0.1
      expect(samples.size).to(eq(count))
    end

    it 'stop! is safe to call twice' do
      observer = described_class.install!(sink: sink)
      observer.stop!
      expect { observer.stop! }.not_to(raise_error)
    end
  end

  describe 'error isolation' do
    let(:boom_sink) { ->(_sample) { raise('sink boom') } }

    after { @observer&.stop! }

    it 'does not propagate when the sink raises on an event' do
      @observer = described_class.install!(sink: boom_sink)
      expect { Apartment::Instrumentation.instrument(:evict, {}) }.not_to(raise_error)
    end

    it 'does not propagate when the sink raises during sample!' do
      allow(Apartment).to(receive(:pool_manager)
        .and_return(instance_double(Apartment::PoolManager, stats: { total_pools: 1, tenants: [] })))
      @observer = described_class.new(sink: boom_sink)
      expect { @observer.sample! }.not_to(raise_error)
    end

    it 'does not propagate when backend_count raises' do
      allow(Apartment).to(receive(:pool_manager)
        .and_return(instance_double(Apartment::PoolManager, stats: { total_pools: 1, tenants: [] })))
      @observer = described_class.new(sink: sink, backend_count: -> { raise('backend boom') })
      expect { @observer.sample! }.not_to(raise_error)
    end

    it 'does not propagate even when the failure logger itself raises' do
      @observer = described_class.install!(sink: boom_sink)
      allow(@observer).to(receive(:warn).and_raise('warn boom'))
      expect { Apartment::Instrumentation.instrument(:evict, {}) }.not_to(raise_error)
    end
  end

  describe '.install! cleanup on partial failure' do
    it 'tears down subscriptions when a later step raises after subscribing' do
      recorded = Concurrent::Array.new
      capturing_sink = ->(sample) { recorded << sample }

      # A non-numeric interval raises NoMethodError at the `positive?` check
      # (inside install!, after subscribe!) — the sampler is never reached.
      expect { described_class.install!(sink: capturing_sink, sample_interval: 'nope') }
        .to(raise_error(NoMethodError))

      # If cleanup worked, the orphaned subscriptions are gone and no event lands.
      Apartment::Instrumentation.instrument(:evict, {})
      expect(recorded).to(be_empty)
    end
  end

  describe '.install! with a non-positive sample_interval' do
    # nil is the intentional "no sampler" signal; a non-nil, non-positive value
    # (e.g. an empty APARTMENT_POOL_SAMPLE_INTERVAL coerced to 0) is almost
    # always a misconfig. Surface it instead of shipping a gauge-less observer.
    it 'warns and does not start the sampler (0)' do
      allow(described_class).to(receive(:warn))
      observer = described_class.install!(sink: sink, sample_interval: 0)

      expect(described_class).to(have_received(:warn).with(/not positive/))
      expect(observer.instance_variable_get(:@sampler)).to(be_nil)
      observer.stop!
    end

    it 'warns for a negative interval too' do
      allow(described_class).to(receive(:warn))
      observer = described_class.install!(sink: sink, sample_interval: -5)

      expect(described_class).to(have_received(:warn).with(/not positive/))
      observer.stop!
    end

    it 'does not warn when the interval is nil (intentional no-sampler)' do
      allow(described_class).to(receive(:warn))
      observer = described_class.install!(sink: sink, sample_interval: nil)

      expect(described_class).not_to(have_received(:warn))
      observer.stop!
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

    it 'promotes :reason into dimensions for any event carrying it (e.g. reaper_stopped)' do
      observer
      Apartment::Instrumentation.instrument(:reaper_stopped, reason: :test_env)

      sample = samples.find { |s| s.name == :reaper_stopped }
      expect(sample.dimensions).to(eq(reason: :test_env))
    end
  end
end
