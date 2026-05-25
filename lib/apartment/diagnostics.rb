# frozen_string_literal: true

module Apartment
  # Opt-in diagnostic that logs (at debug level) every time
  # ConnectionHandling#connection_pool falls through to the default-tenant
  # pool because Apartment::Current.tenant is nil. The same nil-fallback
  # is the silent backdoor behind a class of bugs: a lazy association
  # accessed after its switch block exited, or a load_async relation
  # consumed outside the original switch -- the query runs against the
  # wrong tenant with no error, no warning.
  #
  # The diagnostic deduplicates per call site so a test suite or request
  # flow doesn't get spammed for the same leak. Reset between test runs
  # via {.reset!}.
  #
  # Disabled by default. Adopt via:
  #
  #   Apartment.configure do |config|
  #     config.log_default_tenant_fallback = Rails.env.local?
  #   end
  #
  # Then grep your dev or test log for "[Apartment] tenant=nil" after a
  # session to find every leak site.
  module Diagnostics
    DEDUP_MUTEX = Mutex.new
    private_constant :DEDUP_MUTEX

    # Per-process set of "file:line" call sites already logged. Internal
    # state, exposed only for {.reset!}.
    @seen_sites = Set.new

    class << self
      # Log a single dedup'd debug line for a nil-tenant default-pool
      # fallback. No-op when {Apartment.config} is unset, when the flag
      # is off, or when Rails.logger is unavailable.
      #
      # @param model_class [Class] the AR class on which connection_pool
      #   was invoked (used in the log line for context).
      # @param frames [Array<Thread::Backtrace::Location>] caller frames
      #   passed in by the prepend so we capture the user's call site
      #   rather than this module's.
      def record_default_tenant_fallback(model_class, frames)
        return unless Apartment.config&.log_default_tenant_fallback
        return unless defined?(Rails) && Rails.logger

        site = first_user_site(frames)
        return unless first_seen?(site)

        emit_log_line(model_class, frames, site)
      end

      # Clear the dedup set. Useful in test suites that want each example
      # to start with a fresh slate so per-test leaks surface.
      def reset!
        DEDUP_MUTEX.synchronize { @seen_sites.clear }
      end

      # Currently-recorded sites; intended for tests and debugging.
      def seen_sites
        DEDUP_MUTEX.synchronize { @seen_sites.dup }
      end

      private

      # Skip frames inside this gem and inside common Rails-ecosystem gems
      # so the caller resolves to the user's code, not the deep AR internals
      # that issue the connection_pool call. Without this filter, dedup
      # keys would vary by AR internal call site (one query can touch
      # connection_pool from columns_hash, schema_load, query exec, etc.)
      # and the same user line would log multiple times.
      #
      # Combined into one regex so the negation reads as a single
      # `!match?` -- rubocop-rails' NegateInclude cop would otherwise push
      # a `!include?` toward `String#exclude?`, which is an ActiveSupport
      # extension this module shouldn't depend on.
      INTERNAL_FRAME_PATTERN = %r{
        /apartment(?:[/-])           # this gem (worktree path or installed gem dir)
        | /gems/(?:apartment|active|action|rail)   # Rails ecosystem gems
      }x
      private_constant :INTERNAL_FRAME_PATTERN

      def first_user_site(frames)
        user = frames.find { |f| !f.path.match?(INTERNAL_FRAME_PATTERN) }
        f = user || frames.first
        f ? "#{f.path}:#{f.lineno}" : '(unknown)'
      end

      # Set#add? returns nil when the element is already present, the
      # element itself when newly added. Wrap in the mutex so concurrent
      # threads don't race on first-seen.
      def first_seen?(site)
        DEDUP_MUTEX.synchronize { !!@seen_sites.add?(site) }
      end

      def emit_log_line(model_class, frames, site)
        Rails.logger.debug do
          chain = frames.first(8).map { |f| "  #{f.path}:#{f.lineno}:in `#{f.label}'" }.join("\n")
          '[Apartment] tenant=nil -> default pool fallback. ' \
            "Model=#{model_class.name || model_class.inspect}. Caller=#{site}\n#{chain}"
        end
      end
    end
  end
end
