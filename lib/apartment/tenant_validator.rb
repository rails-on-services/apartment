# frozen_string_literal: true

require 'concurrent'

module Apartment
  # In-process, memoized validator: answers "is this a real tenant name?".
  # The positive set is sourced from config.tenants_provider, refreshed on a
  # TTL and — rate-limited, single-flight — on a miss. Lifecycle invalidation
  # and fail-open behavior are added in a later task.
  class TenantValidator
    DEFAULT_POSITIVE_TTL_SECONDS = 300
    DEFAULT_REBUILD_INTERVAL_SECONDS = 5

    def initialize(positive_ttl: DEFAULT_POSITIVE_TTL_SECONDS,
                   rebuild_interval: DEFAULT_REBUILD_INTERVAL_SECONDS)
      @positive_ttl = positive_ttl
      @rebuild_interval = rebuild_interval
      @names = Concurrent::Set.new
      @mutex = Mutex.new
      @built_at = nil
      @last_rebuild_at = nil
    end

    # @return [Boolean] whether `name` is a known tenant.
    def call(name)
      name = name.to_s
      rebuild if @built_at.nil? || stale?
      return true if @names.include?(name)

      rebuild_on_miss
      @names.include?(name)
    end
    alias valid? call

    private

    def stale?
      @built_at && (monotonic - @built_at) > @positive_ttl
    end

    def rebuild_on_miss
      return if @last_rebuild_at && (monotonic - @last_rebuild_at) < @rebuild_interval

      rebuild
    end

    # Single-flight: one thread rebuilds at a time; others skip and use the
    # current set, rechecking on their next request.
    def rebuild
      return unless @mutex.try_lock

      begin
        @last_rebuild_at = monotonic
        names = Array(Apartment.config.tenants_provider.call).map(&:to_s)
        @names = Concurrent::Set.new(names)
        @built_at = monotonic
      ensure
        @mutex.unlock
      end
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
