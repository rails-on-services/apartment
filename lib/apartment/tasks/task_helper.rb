# frozen_string_literal: true

require 'active_support/core_ext/module/delegation'

module Apartment
  # Helper module for Apartment rake tasks
  # Provides parallel execution, advisory lock management, and error reporting
  module TaskHelper
    # Result structure for tracking tenant operation outcomes
    Result = Struct.new(:tenant, :success, :error, keyword_init: true)

    class << self
      # Iterate over all tenants, executing the block for each
      # Handles parallelism, advisory locks, and error collection
      #
      # @yield [String] tenant name
      # @return [Array<Result>] results for each tenant
      def each_tenant(&)
        return [] if tenants_without_default.empty?

        if parallel_migration_threads.positive?
          each_tenant_parallel(&)
        else
          each_tenant_sequential(&)
        end
      end

      # Iterate over tenants sequentially (no parallelism)
      #
      # @yield [String] tenant name
      # @return [Array<Result>] results for each tenant
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

      # Iterate over tenants in parallel with proper resource management
      #
      # @yield [String] tenant name
      # @return [Array<Result>] results for each tenant
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

      # Execute block for each tenant using process-based parallelism
      # Best for Linux where fork() is safe
      #
      # @yield [String] tenant name
      # @return [Array<Result>] results for each tenant
      def each_tenant_in_processes
        Parallel.map(tenants_without_default, in_processes: parallel_migration_threads) do |tenant|
          # Each forked process needs fresh connections
          ActiveRecord::Base.connection_handler.clear_all_connections!(:all)

          # Establish new connection with advisory locks disabled
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

      # Execute block for each tenant using thread-based parallelism
      # Safe for macOS and Windows where fork() has issues
      #
      # @yield [String] tenant name
      # @return [Array<Result>] results for each tenant
      def each_tenant_in_threads
        # Threads share the connection pool, so we need to reconfigure it once
        # before parallel execution with advisory locks disabled
        original_config = ActiveRecord::Base.connection_db_config.configuration_hash
        reconnect_with_advisory_locks_disabled

        Parallel.map(tenants_without_default, in_threads: parallel_migration_threads) do |tenant|
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
        # Restore original connection configuration
        ActiveRecord::Base.connection_handler.clear_all_connections!(:all)
        ActiveRecord::Base.establish_connection(original_config) if original_config
      end

      # Determine the parallelism strategy based on configuration and platform
      #
      # @return [Symbol] :threads or :processes
      def resolve_parallel_strategy
        strategy = Apartment.parallel_strategy

        return :threads if strategy == :threads
        return :processes if strategy == :processes

        # Auto-detect based on platform
        fork_safe_platform? ? :processes : :threads
      end

      # Check if the current platform supports fork-based parallelism
      #
      # @return [Boolean] true if fork is safe
      def fork_safe_platform?
        # Only Linux supports fork safely
        # macOS has issues with libpq/GSS/Kerberos after fork
        # Windows has no fork() syscall
        # Unknown platforms default to threads (safe option)
        RUBY_PLATFORM.include?('linux')
      end

      # Wrap block with advisory lock management for parallel safety
      #
      # @yield Block to execute with advisory locks disabled
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

      # Reconnect to database with advisory locks explicitly disabled
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
