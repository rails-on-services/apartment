# frozen_string_literal: true

require 'concurrent'
require 'active_support/notifications'

module Apartment
  # In-process, memoized validator: answers "is this a real tenant name?".
  # The positive set is sourced from config.tenants_provider, refreshed on a
  # TTL and — rate-limited, single-flight — on a miss. Lifecycle notifications
  # (create.apartment / drop.apartment) keep the set current between rebuilds;
  # a tenants_provider error makes the validator fail open (allow all names).
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
      @degraded = false
      @subscribers = subscribe_to_lifecycle
    end

    # Remove the ActiveSupport::Notifications subscriptions. Call when
    # discarding a validator (Apartment.clear_config) so subscriptions do
    # not accumulate across a process's lifetime.
    def shutdown
      @subscribers.each { |s| ActiveSupport::Notifications.unsubscribe(s) }
      @subscribers = []
    end

    # @return [Boolean] whether `name` is a known tenant.
    def call(name)
      name = name.to_s
      rebuild if @built_at.nil? || stale?
      return true if @degraded
      return true if @names.include?(name)

      rebuild_on_miss
      @degraded || @names.include?(name)
    end
    alias valid? call

    private

    def stale?
      return false unless @built_at

      ttl = @degraded ? @rebuild_interval : @positive_ttl
      (monotonic - @built_at) > ttl
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
        @degraded = false
        @built_at = monotonic
      rescue StandardError => e
        # Fail open: a broken tenants_provider must not blanket-404 the app.
        @degraded = true
        @built_at = monotonic
        warn_degraded(e)
      ensure
        @mutex.unlock
      end
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def subscribe_to_lifecycle
      [
        ActiveSupport::Notifications.subscribe('create.apartment') do |*args|
          name = args.last[:tenant]
          @names.add(name.to_s) if name
        end,
        ActiveSupport::Notifications.subscribe('drop.apartment') do |*args|
          name = args.last[:tenant]
          @names.delete(name.to_s) if name
        end,
      ]
    end

    def warn_degraded(error)
      message = '[Apartment] tenant validation degraded: tenants_provider raised ' \
                "#{error.class}: #{error.message}. Allowing all tenants until it recovers."
      if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
        Rails.logger.error(message)
      else
        warn(message)
      end
    end
  end
end
