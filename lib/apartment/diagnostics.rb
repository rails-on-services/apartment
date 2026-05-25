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

      # Path prefix for *this* gem's source, captured from __dir__ at load
      # time. Covers local development / worktrees / source-installed gems.
      # Using an exact prefix avoids the false positives that a substring
      # match on "apartment" would cause -- e.g., an adopter app under
      # `/Users/dev/my-apartment-service/` would otherwise have all its
      # user frames filtered as "internal" and the diagnostic would
      # resolve to deep AR frames.
      GEM_ROOT = __dir__.freeze
      private_constant :GEM_ROOT

      # Anchor on `/gems/(name)-<digit>` so a gem installed via Bundler
      # (where the path is `.../gems/<gem>-<version>/...`) is filtered
      # without also matching adopter app paths that happen to contain
      # the gem's name as a substring. Mirrors how Rails core gems are
      # filtered below.
      INSTALLED_GEM_FRAME_PATTERN = %r{/gems/apartment-\d}.freeze
      private_constant :INSTALLED_GEM_FRAME_PATTERN

      # Concrete Rails core gem directory name prefixes. Explicit list
      # (instead of a `/(active|action|rail)/` prefix sweep) so non-core
      # gems with similar names -- active_model_serializers, activeadmin,
      # action_policy, rails_admin -- stay visible. If a leak originates
      # from one of those, the user wants to see it, not have it hidden
      # behind AR internals.
      RAILS_CORE_GEMS = %w[
        activerecord activesupport activemodel activejob
        actionpack actionview actionmailer actioncable
        actionmailbox actiontext railties rails
      ].freeze
      private_constant :RAILS_CORE_GEMS

      RAILS_CORE_FRAME_PATTERN = %r{/gems/(?:#{RAILS_CORE_GEMS.join('|')})-\d}.freeze
      private_constant :RAILS_CORE_FRAME_PATTERN

      # First frame outside this gem (source or installed) and outside
      # Rails core. That's the user's code (or a non-core gem like an
      # engine or serializer where a leak is still actionable).
      #
      # Without this filter, one query can hit connection_pool from
      # multiple AR internal sites (columns_hash, schema_load, query exec)
      # at different file:line each -- dedup would treat them as distinct
      # "leaks" and log multiple times for one user mistake.
      def first_user_site(frames)
        user = frames.find do |f|
          !f.path.start_with?(GEM_ROOT) &&
            !f.path.match?(INSTALLED_GEM_FRAME_PATTERN) &&
            !f.path.match?(RAILS_CORE_FRAME_PATTERN)
        end
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
