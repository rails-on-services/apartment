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

    def initialize(sink:, backend_count: nil)
      raise(ArgumentError, 'sink must be callable') unless sink.respond_to?(:call)

      @sink = sink
      @backend_count = backend_count
      @subscribers = []
      @sampler = nil
    end
  end
end
