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
      if sample_interval.nil?
        # nil is the intentional "no gauge sampler" signal; counters still flow.
      elsif sample_interval.positive?
        observer.start_sampler!(interval: sample_interval)
      else
        # A non-nil, non-positive interval is almost always a misconfig (e.g. an
        # empty APARTMENT_POOL_SAMPLE_INTERVAL coerced to 0). Silently skipping
        # the sampler ships an observer whose gauges never emit; surface it.
        warn "[Apartment::PoolObserver] sample_interval=#{sample_interval.inspect} is not " \
             'positive; gauge sampler not started (tenant_pools_live/backend_connections ' \
             'will not emit). Pass a positive interval, or nil to disable the sampler.'
      end
      observer
    rescue StandardError
      # Don't leak subscriptions if a later step (e.g. a bad sample_interval)
      # raises after subscribe! has registered listeners.
      observer&.stop!
      raise
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
        @subscribers << ActiveSupport::Notifications.subscribe("#{event}.apartment") do |*, payload|
          record_event(event, payload || {})
        end
      end
      self
    end

    # One gauge pass: live tenant-pool count, plus the adopter's backend count
    # when supplied. Safe to call from start_sampler! or an external scheduler.
    def sample!
      total = Apartment.pool_manager&.stats&.fetch(:total_pools, 0) || 0
      emit_gauge(:tenant_pools_live, total)
      emit_checkout_pressure!

      return unless @backend_count

      backends = @backend_count.call
      return if backends.nil?

      emit_gauge(:backend_connections, backends)
    rescue StandardError => e
      warn_failure('sample!', e)
    end

    def start_sampler!(interval:)
      @sampler&.shutdown
      @sampler = Concurrent::TimerTask.new(execution_interval: interval) { sample! }
      @sampler.execute
      @sampler
    end

    # Unsubscribe from all events and shut down the sampler. Safe to call twice.
    def stop!
      @subscribers.each { |subscriber| ActiveSupport::Notifications.unsubscribe(subscriber) }
      @subscribers.clear
      shutdown_sampler!
    end

    private

    # shutdown stops future ticks; wait_for_termination ensures an in-flight
    # sample! can't emit after stop! returns (mirrors PoolReaper#stop_internal).
    def shutdown_sampler!
      return unless @sampler

      @sampler.shutdown
      @sampler.wait_for_termination(5)
      @sampler = nil
    end

    # Per-tenant-pool checkout pressure, aggregated to low cardinality. waiting>0
    # means threads are blocked acquiring a connection (the same-tenant fan-out
    # starvation signal). The worst tenant is carried in the Sample payload, NOT
    # as a metric dimension, to avoid unbounded time-series churn. Per-pool #stat
    # is rescued so a pool tearing down mid-sample can't abort the whole pass.
    def emit_checkout_pressure!
      manager = Apartment.pool_manager
      return unless manager

      stats = collect_pool_stats(manager)
      worst = stats.max_by { |s| s[:pending] } || { tenant: nil, pending: 0 }
      payload = worst[:pending].positive? ? { tenant: worst[:tenant] } : {}

      emit_gauge(:pools_waiting, stats.count { |s| s[:pending].positive? })
      emit_gauge(:pools_saturated, stats.count { |s| s[:saturated] })
      emit_gauge(:max_checkout_waiting, worst[:pending], payload: payload)
    end

    def emit_gauge(name, value, payload: {})
      emit(Sample.new(name: name, kind: :gauge, value: value, dimensions: {}, payload: payload))
    end

    # Read each tenant pool's checkout stats into [{ tenant:, pending:, saturated: }],
    # skipping any pool whose #stat raises (mid-teardown) so one bad pool can't
    # abort the whole pass.
    def collect_pool_stats(manager)
      stats = []
      manager.each_pair do |tenant_key, pool|
        stat = pool.stat
        stats << { tenant: tenant_key, pending: stat[:waiting].to_i,
                   saturated: stat[:busy].to_i >= stat[:size].to_i }
      rescue StandardError
        next
      end
      stats
    end

    def record_event(event, payload)
      # Copy the notification payload so a sink that mutates Sample#payload
      # can't corrupt it for other subscribers of the same event.
      payload = payload.dup
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
    rescue StandardError
      # The failure logger must never be the thing that raises into the gem's
      # instrumentation path (e.g. a closed/replaced $stderr).
      nil
    end
  end
end
