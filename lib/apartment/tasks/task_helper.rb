# frozen_string_literal: true

require 'active_support/core_ext/module/delegation'

module Apartment
  # Coordinates tenant operations for rake tasks with parallel execution support.
  #
  # ## Problem Context
  #
  # Multi-tenant applications with many schemas face slow migration times when
  # running sequentially. A 100-tenant system with 2-second migrations takes
  # 3+ minutes sequentially but ~20 seconds with 10 parallel workers.
  #
  # ## Why This Design
  #
  # Parallel database migrations introduce two categories of problems:
  #
  # 1. **Platform-specific fork safety**: macOS/Windows have issues with libpq
  #    (PostgreSQL C library) after fork() due to GSS/Kerberos state corruption.
  #    Linux handles fork() cleanly. We auto-detect and choose the safe strategy.
  #
  # 2. **PostgreSQL advisory lock deadlocks**: Rails uses advisory locks to
  #    prevent concurrent migrations. When multiple processes/threads migrate
  #    different schemas simultaneously, they deadlock competing for the same
  #    lock. We disable advisory locks during parallel execution, which means
  #    **you accept responsibility for ensuring your migrations are parallel-safe**.
  #
  # ## When to Use Parallel Migrations
  #
  # This is an advanced feature. Use it when:
  # - You have many tenants and sequential migration time is problematic
  # - Your migrations only modify tenant-specific schema objects
  # - You've verified your migrations don't have cross-schema side effects
  #
  # Stick with sequential execution (the default) when:
  # - Migrations create/modify extensions, types, or shared objects
  # - Migrations have ordering dependencies across tenants
  # - You're unsure whether parallel execution is safe for your use case
  #
  # ## Gotchas
  #
  # - The `parallel_migration_threads` count should be less than your connection
  #   pool size to avoid connection exhaustion.
  # - Empty/nil tenant names from `tenant_names` proc are filtered to prevent
  #   PostgreSQL "zero-length delimited identifier" errors.
  # - Process-based parallelism requires fresh connections in each fork;
  #   thread-based parallelism shares the pool but needs explicit checkout.
  #
  # @see Apartment.parallel_migration_threads
  # @see Apartment.parallel_strategy
  # @see Apartment.manage_advisory_locks
  module TaskHelper
    # Captures outcome per tenant for aggregated reporting. Allows migrations
    # to continue for remaining tenants even when one fails.
    Result = Struct.new(:tenant, :success, :error, keyword_init: true)

    class << self
      # Primary entry point for tenant iteration. Automatically selects
      # sequential or parallel execution based on configuration.
      #
      # @yield [String] tenant name
      # @return [Array<Result>] outcome for each tenant
      def each_tenant(&)
        return [] if tenants_without_default.empty?

        if parallel_migration_threads.positive?
          each_tenant_parallel(&)
        else
          each_tenant_sequential(&)
        end
      end

      # Sequential execution: simpler, no connection management complexity.
      # Used when parallel_migration_threads is 0 (the default).
      def each_tenant_sequential
        tenants_without_default.map do |tenant|
          Rails.application.executor.wrap do
            yield(tenant)
          end
          Result.new(tenant: tenant, success: true, error: nil)
        rescue StandardError => e
          Result.new(tenant: tenant, success: false, error: e.message)
        end
      end

      # Parallel execution wrapper. Disables advisory locks for the duration,
      # then delegates to platform-appropriate parallelism strategy.
      def each_tenant_parallel(&)
        with_advisory_locks_disabled do
          case resolve_parallel_strategy
          when :processes
            each_tenant_in_processes(&)
          else
            each_tenant_in_threads(&)
          end
        end
      end

      # Process-based parallelism via fork(). Faster on Linux due to
      # copy-on-write memory and no GIL contention. Each forked process
      # gets isolated memory, so we must clear inherited connections
      # and establish fresh ones.
      def each_tenant_in_processes
        Parallel.map(tenants_without_default, in_processes: parallel_migration_threads) do |tenant|
          # Forked processes inherit parent's connection handles but the
          # underlying sockets are invalid. Must reconnect before any DB work.
          ActiveRecord::Base.connection_handler.clear_all_connections!(:all)
          reconnect_with_advisory_locks_disabled

          Rails.application.executor.wrap do
            yield(tenant)
          end
          Result.new(tenant: tenant, success: true, error: nil)
        rescue StandardError => e
          Result.new(tenant: tenant, success: false, error: e.message)
        ensure
          ActiveRecord::Base.connection_handler.clear_all_connections!(:all)
        end
      end

      # Thread-based parallelism. Safe on all platforms but subject to GIL
      # for CPU-bound work (migrations are typically I/O-bound, so this is fine).
      # Threads share the connection pool, so we reconfigure once before
      # spawning and restore after completion.
      def each_tenant_in_threads
        original_config = ActiveRecord::Base.connection_db_config.configuration_hash
        reconnect_with_advisory_locks_disabled

        Parallel.map(tenants_without_default, in_threads: parallel_migration_threads) do |tenant|
          # Explicit connection checkout prevents pool exhaustion when
          # thread count exceeds pool size minus buffer.
          ActiveRecord::Base.connection_pool.with_connection do
            Rails.application.executor.wrap do
              yield(tenant)
            end
          end
          Result.new(tenant: tenant, success: true, error: nil)
        rescue StandardError => e
          Result.new(tenant: tenant, success: false, error: e.message)
        end
      ensure
        ActiveRecord::Base.connection_handler.clear_all_connections!(:all)
        ActiveRecord::Base.establish_connection(original_config) if original_config
      end

      # Auto-detection logic for parallelism strategy. Only Linux gets
      # process-based parallelism by default due to macOS libpq fork issues.
      def resolve_parallel_strategy
        strategy = Apartment.parallel_strategy

        return :threads if strategy == :threads
        return :processes if strategy == :processes

        fork_safe_platform? ? :processes : :threads
      end

      # Platform detection. Conservative: only Linux is considered fork-safe.
      # macOS has documented issues with libpq, GSS-API, and Kerberos after fork.
      # See: https://www.postgresql.org/docs/current/libpq-connect.html#LIBPQ-CONNECT-GSSENCMODE
      def fork_safe_platform?
        RUBY_PLATFORM.include?('linux')
      end

      # Advisory lock management. Rails acquires pg_advisory_lock during migrations
      # to prevent concurrent schema changes. With parallel tenant migrations,
      # this causes deadlocks since all workers compete for the same lock.
      #
      # **Important**: Disabling advisory locks shifts responsibility to you.
      # Your migrations must be safe to run concurrently across tenants. If your
      # migrations modify shared resources, create extensions, or have other
      # cross-schema side effects, parallel execution may cause failures.
      # When in doubt, use sequential execution (parallel_migration_threads = 0).
      #
      # Uses ENV var because Rails checks it at connection establishment time,
      # and we need it disabled before Parallel spawns workers.
      def with_advisory_locks_disabled
        return yield unless parallel_migration_threads.positive?
        return yield unless Apartment.manage_advisory_locks

        original_env_value = ENV.fetch('DISABLE_ADVISORY_LOCKS', nil)
        begin
          ENV['DISABLE_ADVISORY_LOCKS'] = 'true'
          yield
        ensure
          if original_env_value.nil?
            ENV.delete('DISABLE_ADVISORY_LOCKS')
          else
            ENV['DISABLE_ADVISORY_LOCKS'] = original_env_value
          end
        end
      end

      # Establishes connection with advisory_locks: false in the config hash.
      # Belt-and-suspenders with the ENV var approach above.
      def reconnect_with_advisory_locks_disabled
        current_config = ActiveRecord::Base.connection_db_config.configuration_hash
        new_config = current_config.merge(advisory_locks: false)
        ActiveRecord::Base.establish_connection(new_config)
      end

      # Delegate to Apartment.parallel_migration_threads
      delegate :parallel_migration_threads, to: Apartment

      # Get list of tenants excluding the default tenant
      # Also filters out blank/empty tenant names to prevent errors
      #
      # @return [Array<String>] tenant names
      def tenants_without_default
        (tenants - [Apartment.default_tenant]).reject { |t| t.nil? || t.to_s.strip.empty? }
      end

      # Get list of all tenants to operate on
      # Supports DB env var for targeting specific tenants
      # Filters out blank tenant names for safety
      #
      # @return [Array<String>] tenant names
      def tenants
        result = ENV['DB'] ? ENV['DB'].split(',').map(&:strip) : Apartment.tenant_names || []
        result.reject { |t| t.nil? || t.to_s.strip.empty? }
      end

      # Display warning if tenant list is empty
      def warn_if_tenants_empty
        return unless tenants.empty? && ENV['IGNORE_EMPTY_TENANTS'] != 'true'

        puts <<~WARNING
          [WARNING] - The list of tenants to migrate appears to be empty. This could mean a few things:

            1. You may not have created any, in which case you can ignore this message
            2. You've run `apartment:migrate` directly without loading the Rails environment
              * `apartment:migrate` is now deprecated. Tenants will automatically be migrated with `db:migrate`

          Note that your tenants currently haven't been migrated. You'll need to run `db:migrate` to rectify this.
        WARNING
      end

      # Display summary of operation results
      #
      # @param operation [String] name of the operation (e.g., "Migration", "Rollback")
      # @param results [Array<Result>] results from each_tenant
      def display_summary(operation, results)
        return if results.empty?

        succeeded = results.count(&:success)
        failed = results.reject(&:success)

        puts "\n=== #{operation} Summary ==="
        puts "Succeeded: #{succeeded}/#{results.size} tenants"

        return if failed.empty?

        puts "Failed: #{failed.size} tenants"
        failed.each do |result|
          puts "  - #{result.tenant}: #{result.error}"
        end
      end

      # Create a tenant with logging
      #
      # @param tenant_name [String] name of tenant to create
      def create_tenant(tenant_name)
        puts("Creating #{tenant_name} tenant")
        Apartment::Tenant.create(tenant_name)
      rescue Apartment::TenantExists => e
        puts "Tried to create already existing tenant: #{e}"
      end

      # Migrate a single tenant with error handling based on strategy
      #
      # @param tenant_name [String] name of tenant to migrate
      def migrate_tenant(tenant_name)
        strategy = Apartment.db_migrate_tenant_missing_strategy
        create_tenant(tenant_name) if strategy == :create_tenant

        puts("Migrating #{tenant_name} tenant")
        Apartment::Migrator.migrate(tenant_name)
      rescue Apartment::TenantNotFound => e
        raise(e) if strategy == :raise_exception

        puts e.message
      end
    end
  end
end
