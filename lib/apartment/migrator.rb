# frozen_string_literal: true

require 'concurrent'
require_relative 'instrumentation'
require_relative 'errors'

module Apartment
  class Migrator
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

    def initialize(threads: 0)
      @threads = threads
    end

    def run # rubocop:disable Metrics/MethodLength
      start = monotonic_now

      primary_result = migrate_primary

      if primary_result.status == :failed
        return MigrationRun.new(
          results: [primary_result],
          total_duration: monotonic_now - start,
          threads: @threads
        )
      end

      tenants = Apartment.config.tenants_provider.call
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
    end

    private

    # Migrate the primary (default) tenant using AR::Base's existing pool.
    # No tenant switch needed — the default connection is already correct.
    def migrate_primary # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      tenant_name = Apartment.config.default_tenant || 'public'
      start = monotonic_now

      context = ActiveRecord::Base.connection_pool.migration_context

      unless context.needs_migration?
        return Result.new(
          tenant: tenant_name, status: :skipped,
          duration: monotonic_now - start, error: nil, versions_run: []
        )
      end

      raw_versions = context.migrate
      versions = Array(raw_versions).map { _1.respond_to?(:version) ? _1.version : _1 }

      Instrumentation.instrument(:migrate_tenant, tenant: tenant_name, versions: versions)

      Result.new(
        tenant: tenant_name, status: :success,
        duration: monotonic_now - start, error: nil, versions_run: versions
      )
    rescue StandardError => e
      Result.new(
        tenant: tenant_name, status: :failed,
        duration: monotonic_now - start, error: e, versions_run: []
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

      Apartment::Tenant.switch(tenant) do
        pool = ActiveRecord::Base.connection_pool
        context = pool.migration_context

        unless context.needs_migration?
          return Result.new(
            tenant: tenant, status: :skipped,
            duration: monotonic_now - start, error: nil, versions_run: []
          )
        end

        # Disable advisory locks on the leased connection. lease_connection
        # returns the same object for the current thread, so the flag is
        # still set when context.migrate checks advisory_locks_enabled?.
        ActiveRecord::Base.lease_connection.instance_variable_set(:@advisory_locks_enabled, false)
        raw_versions = context.migrate
        versions = Array(raw_versions).map { _1.respond_to?(:version) ? _1.version : _1 }

        Instrumentation.instrument(:migrate_tenant, tenant: tenant, versions: versions)

        Result.new(
          tenant: tenant, status: :success,
          duration: monotonic_now - start, error: nil, versions_run: versions
        )
      end
    rescue StandardError => e
      Result.new(
        tenant: tenant, status: :failed,
        duration: monotonic_now - start, error: e, versions_run: []
      )
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

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
