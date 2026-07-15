# frozen_string_literal: true

require 'concurrent'
require_relative 'instrumentation'
require_relative 'errors'

module Apartment
  class Migrator # rubocop:disable Metrics/ClassLength
    # ActiveRecord exposes no public setter for advisory-lock state (only the
    # advisory_locks_enabled? reader), so we toggle this private ivar directly.
    # The guard in with_advisory_locks_disabled detects a future Rails rename.
    ADVISORY_LOCKS_IVAR = :@advisory_locks_enabled

    Result = Data.define(
      :tenant,
      :status,
      :duration,
      :error,
      :versions_run
    )

    MigrationRun = Data.define(
      :results,
      :total_duration,
      :threads
    ) do
      def succeeded = results.select { _1.status == :success }
      def failed    = results.select { _1.status == :failed }
      def skipped   = results.select { _1.status == :skipped }
      def success?  = failed.empty?

      def summary # rubocop:disable Metrics/AbcSize
        lines = []
        lines << "Migrated #{results.size} tenants in #{total_duration.round(1)}s (#{threads} threads)"
        lines << "  #{succeeded.size} succeeded" if succeeded.any?
        if failed.any?
          lines << "  #{failed.size} failed:"
          failed.each { |r| lines << "    #{r.tenant}: #{r.error&.class}: #{r.error&.message}" }
        end
        lines << "  #{skipped.size} skipped (up to date)" if skipped.any?
        lines.join("\n")
      end
    end

    # Wrap a block in connected_to(role: migration_role) when configured.
    # Class method so both Migrator internals and CLI commands can share
    # the same RBAC role-switching logic without duplication.
    def self.with_migration_role(&)
      role = Apartment.config.migration_role
      role ? ActiveRecord::Base.connected_to(role: role, &) : yield
    end

    def initialize(threads: 0, version: nil)
      @threads = threads
      @version = version
    end

    def run # rubocop:disable Metrics/MethodLength
      start = monotonic_now

      primary_result = with_migration_role { migrate_primary }

      if primary_result.status == :failed
        return MigrationRun.new(
          results: [primary_result],
          total_duration: monotonic_now - start,
          threads: @threads
        )
      end

      tenants = Apartment.tenant_names
      tenant_results = if @threads.positive?
                         run_parallel(tenants)
                       else
                         run_sequential(tenants)
                       end

      all_results = [primary_result, *tenant_results].compact

      MigrationRun.new(
        results: all_results,
        total_duration: monotonic_now - start,
        threads: @threads
      )
    ensure
      evict_migration_pools
    end

    # Migrate a single named tenant. Returns a Result.
    # Evicts migration-role pools in ensure regardless of outcome.
    def migrate_one(tenant)
      migrate_tenant(tenant)
    ensure
      evict_migration_pools
    end

    private

    # Migrate the primary (default) tenant using AR::Base's existing pool.
    # No tenant switch needed — the default connection is already correct.
    def migrate_primary # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      tenant_name = Apartment.config.default_tenant
      start = monotonic_now

      context = ActiveRecord::Base.connection_pool.migration_context

      unless @version || context.needs_migration?
        return Result.new(
          tenant: tenant_name, status: :skipped,
          duration: monotonic_now - start, error: nil, versions_run: []
        )
      end

      raw_versions = context.migrate(@version)
      versions = Array(raw_versions).map { _1.respond_to?(:version) ? _1.version : _1 }

      Instrumentation.instrument(:migrate_tenant, tenant: tenant_name, versions: versions)

      Result.new(
        tenant: tenant_name, status: :success,
        duration: monotonic_now - start, error: nil, versions_run: versions
      )
    rescue StandardError => e
      duration = monotonic_now - start
      # Symmetric with the :migrate_tenant success event above: the gem holds the
      # full structured error here, so emit it for subscribers rather than
      # stranding it in the returned Result. See migrate_tenant's rescue.
      instrument_failure(tenant_name, e, duration)

      Result.new(
        tenant: tenant_name, status: :failed,
        duration: duration, error: e, versions_run: []
      )
    end

    # Migrate a single tenant by switching via Apartment::Tenant.switch.
    # The ConnectionHandling patch routes AR::Base.connection_pool to the
    # tenant's pool, so Rails' migration machinery (which always goes through
    # AR::Base) uses the correct connection automatically.
    #
    # Advisory locks are disabled for tenant migrations. PG's advisory locks
    # are database-wide, so they serialize all parallel tenant migrations into
    # sequential execution. Disabling them is a known trade-off: a migration
    # that performs cross-tenant operations could race, but schema-scoped locks
    # wouldn't prevent that either (see apartment issue #298).
    def migrate_tenant(tenant) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      start = monotonic_now
      Apartment::Current.migrating = true

      with_migration_role do
        Apartment::Tenant.switch(tenant) do
          context = ActiveRecord::Base.connection_pool.migration_context

          unless @version || context.needs_migration?
            return Result.new(
              tenant: tenant, status: :skipped,
              duration: monotonic_now - start, error: nil, versions_run: []
            )
          end

          with_advisory_locks_disabled do
            raw_versions = context.migrate(@version)
            versions = Array(raw_versions).map { _1.respond_to?(:version) ? _1.version : _1 }

            Instrumentation.instrument(:migrate_tenant, tenant: tenant, versions: versions)

            Result.new(
              tenant: tenant, status: :success,
              duration: monotonic_now - start, error: nil, versions_run: versions
            )
          end
        end
      end
    rescue StandardError => e
      duration = monotonic_now - start
      # Failure counterpart to the :migrate_tenant success event. On SUCCESS the
      # gem instruments; on FAILURE it previously only returned a failed Result,
      # leaving adopters no hook to observe the (structured) error. This closes
      # that asymmetry — generic payload (tenant + error + duration); routing to
      # an error tracker is the subscriber's job.
      instrument_failure(tenant, e, duration)

      Result.new(
        tenant: tenant, status: :failed,
        duration: duration, error: e, versions_run: []
      )
    ensure
      Apartment::Current.migrating = false
    end

    def run_sequential(tenants)
      tenants.map { |tenant| migrate_tenant(tenant) }
    end

    def run_parallel(tenants) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      work_queue = Queue.new
      tenants.each { |t| work_queue << t }
      @threads.times { work_queue << :done }

      results = Concurrent::Array.new
      fatal_errors = Concurrent::Array.new

      workers = Array.new(@threads) do
        Thread.new do # rubocop:disable ThreadSafety/NewThread
          while (tenant = work_queue.pop) != :done
            results << migrate_tenant(tenant)
          end
        rescue Exception => e # rubocop:disable Lint/RescueException
          fatal_errors << e
        end
      end

      workers.each(&:join)
      raise(fatal_errors.first) if fatal_errors.any?

      results.to_a
    end

    def with_migration_role(&) = self.class.with_migration_role(&)

    def evict_migration_pools
      role = Apartment.config.migration_role
      return unless role && Apartment.pool_manager

      Apartment.pool_manager.evict_by_role(role).each do |pool_key, pool|
        # evict_by_role already removed it from the manager, so deregister_shard has
        # nothing left to disconnect; close it here or a pool AR no longer registers
        # leaks its backend. See docs/designs/out-of-band-tenant-ddl.md.
        Apartment.disconnect_removed_pool(pool, pool_key)
        Apartment.deregister_shard(pool_key)
      end
    rescue StandardError => e
      warn "[Apartment::Migrator] Pool eviction failed: #{e.class}: #{e.message}"
    end

    # Disable advisory locks on the leased connection for the duration of the
    # block, then restore the original value. lease_connection returns the same
    # connection object for the current thread (fiber-local via IsolatedExecutionState).
    #
    # PG's advisory locks are database-wide and would serialize parallel tenant
    # migrations (issue #298). Rails offers no public setter, so we poke the
    # private @advisory_locks_enabled ivar. The instance_variable_defined? guard
    # detects a future Rails *rename or removal* of the ivar (a name-presence
    # check — it does NOT catch a semantics change where Rails keeps the ivar but
    # stops honoring it on the lock path). On a detected rename we warn and
    # proceed rather than silently creating an orphan ivar; the ivar contract is
    # also unit-tested against a real connection so a rename breaks CI first.
    def with_advisory_locks_disabled
      conn = ActiveRecord::Base.lease_connection
      unless conn.instance_variable_defined?(ADVISORY_LOCKS_IVAR)
        warn "[Apartment::Migrator] ActiveRecord connection #{conn.class} does not define " \
             "#{ADVISORY_LOCKS_IVAR}; cannot disable advisory locks for this Rails version. " \
             'Parallel tenant migrations may serialize or fail on the database-wide advisory lock.'
        return yield
      end
      original = conn.instance_variable_get(ADVISORY_LOCKS_IVAR)
      conn.instance_variable_set(ADVISORY_LOCKS_IVAR, false)
      yield
    ensure
      conn.instance_variable_set(ADVISORY_LOCKS_IVAR, original) if conn&.instance_variable_defined?(ADVISORY_LOCKS_IVAR)
    end

    # Emit the failure event without letting a raising subscriber break the
    # Migrator's non-raising contract: the failed Result MUST still be returned.
    # ActiveSupport::Notifications propagates subscriber exceptions through
    # instrument (verified against AS 8.0), and this fires from inside a rescue
    # block, so an un-isolated call would convert a captured per-tenant failure
    # into an unhandled raise out of #run.
    #
    # Scope of the guarantee: a subscriber raising a StandardError is swallowed
    # and warned. Process-control exceptions (SystemExit, SignalException /
    # Interrupt) are deliberately NOT rescued — they must propagate so exit and
    # Ctrl-C still work mid-migration; a subscriber raising a bare Exception
    # subclass is itself a bug (Ruby errors should descend from StandardError).
    # The warn is nested-rescued so a broken $stderr (IOError is a StandardError)
    # cannot re-escape the handler. Success-path instrumentation is left
    # un-isolated by design — only the failure path carries the hard no-raise
    # guarantee, and swallowing there would mask real subscriber bugs.
    def instrument_failure(tenant, error, duration)
      Instrumentation.instrument(:migrate_tenant_failed, tenant: tenant, error: error, duration: duration)
    rescue StandardError => e
      # Nested rescue: a sibling `rescue` on this method would NOT catch an
      # exception raised by warn (a broken $stderr), so the warn gets its own.
      begin
        warn "[Apartment::Migrator] migrate_tenant_failed subscriber raised #{e.class}: #{e.message}"
      rescue StandardError
        nil
      end
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
