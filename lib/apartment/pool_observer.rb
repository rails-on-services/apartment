# frozen_string_literal: true

require 'concurrent'

module Apartment
  # Sink-agnostic observer for the v4 pool lifecycle. Subscribes to the gem's
  # ActiveSupport::Notifications and forwards a normalized Sample to a caller-
  # supplied sink; optionally samples pool gauges on an interval. Ships no
  # transport — the adopter's sink maps Samples to CloudWatch/StatsD/logs/etc.
  # All sink/sampler calls are error-isolated: telemetry must never raise into
  # the gem's instrumentation or timer path. See docs/observability.md.
  class PoolObserver
    # name: Symbol (:evict, :tenant_pools_live, ...); kind: :counter | :gauge;
    # value: Numeric; dimensions: Hash (curated, e.g. { reason: :idle });
    # payload: the raw notification payload (counters) or {} (gauges).
    Sample = Data.define(:name, :kind, :value, :dimensions, :payload)

    # Pool-lifecycle events forwarded as counters (value 1 each).
    COUNTER_EVENTS = %i[create evict cap_unmet skip_evict reaper_stopped].freeze

    # Build, subscribe, and (optionally) start the gauge sampler. Returns the
    # observer; call #stop! to tear it down. Idempotent subscription is NOT
    # guaranteed — install once per process (e.g. an after_initialize hook).
    def self.install!(sink:, sample_interval: nil, backend_count: nil)
      observer = new(sink: sink, backend_count: backend_count)
      observer.subscribe!
      observer.start_sampler!(interval: sample_interval) if sample_interval&.positive?
      observer
    end

    def initialize(sink:, backend_count: nil)
      raise(ArgumentError, 'sink must be callable') unless sink.respond_to?(:call)

      @sink = sink
      @backend_count = backend_count
      @subscribers = []
      @sampler = nil
    end

    def subscribe!
      COUNTER_EVENTS.each do |event|
        subscriber = ActiveSupport::Notifications.subscribe("#{event}.apartment") do |_name, _start, _finish, _id, payload|
          record_event(event, payload || {})
        end
        @subscribers << subscriber
      end
      self
    end

    # One gauge pass: live tenant-pool count, plus the adopter's backend count
    # when supplied. Safe to call from start_sampler! or an external scheduler.
    def sample!
      total = Apartment.pool_manager&.stats&.fetch(:total_pools, 0) || 0
      emit(Sample.new(name: :tenant_pools_live, kind: :gauge, value: total, dimensions: {}, payload: {}))

      return unless @backend_count

      backends = @backend_count.call
      return if backends.nil?

      emit(Sample.new(name: :backend_connections, kind: :gauge, value: backends, dimensions: {}, payload: {}))
    rescue StandardError => e
      warn_failure('sample!', e)
    end

    # Temporary stub — replaced by full implementation in Task 4.
    def start_sampler!(interval:); end # rubocop:disable Style/Semicolon

    # Temporary stub — replaced by full implementation in Task 4.
    def stop!
      @subscribers.each { |s| ActiveSupport::Notifications.unsubscribe(s) }
      @subscribers.clear
    end

    private

    def record_event(event, payload)
      dimensions = payload[:reason] ? { reason: payload[:reason] } : {}
      emit(Sample.new(name: event, kind: :counter, value: 1, dimensions: dimensions, payload: payload))
    rescue StandardError => e
      warn_failure("record_event(#{event})", e)
    end

    def emit(sample)
      @sink.call(sample)
    rescue StandardError => e
      warn_failure("sink(#{sample.name})", e)
    end

    def warn_failure(context, error)
      warn "[Apartment::PoolObserver] #{context} failed: #{error.class}: #{error.message}"
    end
  end
end
