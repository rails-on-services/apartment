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
      @rebuild_mutex = Mutex.new # single-flight guard: one rebuild at a time
      @state_mutex = Mutex.new   # guards the @names swap vs lifecycle deltas
      @pending_deltas = nil      # non-nil Array while a rebuild is in flight
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
      if @built_at.nil?
        rebuild(blocking: true) # cold start: every caller waits for the first build
      elsif stale?
        rebuild                 # refresh: single-flight, non-blocking
      end
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

    # Single-flight. The first build is +blocking+ — concurrent callers wait
    # for it rather than evaluating against the empty initial set, which would
    # 404 a valid tenant. Refreshes are non-blocking: a caller that loses the
    # lock uses the still-valid current set and rechecks on its next request.
    def rebuild(blocking: false)
      if blocking
        @rebuild_mutex.synchronize { perform_rebuild if @built_at.nil? }
      else
        return unless @rebuild_mutex.try_lock

        begin
          perform_rebuild
        ensure
          @rebuild_mutex.unlock
        end
      end
    end

    # Rebuilds the positive set from the source. The slow provider call runs
    # without @state_mutex held, so lifecycle notifications never block on it;
    # deltas that arrive during the call are captured and re-applied to the
    # new set, so the whole-set swap cannot lose a concurrent create/drop.
    def perform_rebuild
      @last_rebuild_at = monotonic
      @state_mutex.synchronize { @pending_deltas = [] }
      fresh = Array(Apartment.config.tenants_provider.call).map(&:to_s)
      commit_rebuild(Concurrent::Set.new(fresh))
    rescue StandardError => e
      # Fail open: a broken tenants_provider must not blanket-404 the app.
      mark_degraded
      warn_degraded(e)
    end

    # Swap in the freshly built set, re-applying any lifecycle deltas that
    # arrived during the (unlocked) provider call so the swap loses nothing.
    def commit_rebuild(new_set)
      @state_mutex.synchronize do
        @pending_deltas.each { |op, name| op == :add ? new_set.add(name) : new_set.delete(name) }
        @pending_deltas = nil
        @names = new_set
        @degraded = false
        @built_at = monotonic
      end
    end

    def mark_degraded
      @state_mutex.synchronize do
        @pending_deltas = nil
        @degraded = true
        @built_at = monotonic
      end
    end

    # Apply a lifecycle change to the live set. While a rebuild is in flight
    # the delta is also recorded, so perform_rebuild re-applies it after the
    # whole-set swap rather than discarding it.
    def apply_lifecycle(operation, name)
      return unless name

      name = name.to_s
      @state_mutex.synchronize do
        operation == :add ? @names.add(name) : @names.delete(name)
        @pending_deltas << [operation, name] if @pending_deltas
      end
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def subscribe_to_lifecycle
      [
        ActiveSupport::Notifications.subscribe('create.apartment') do |*args|
          apply_lifecycle(:add, args.last[:tenant])
        end,
        ActiveSupport::Notifications.subscribe('drop.apartment') do |*args|
          apply_lifecycle(:remove, args.last[:tenant])
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
    rescue StandardError
      # Logging must never break the request path.
      nil
    end
  end
end
