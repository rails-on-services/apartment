# frozen_string_literal: true

require 'concurrent'
require_relative 'pool_manager'
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

      def summary
        lines = []
        lines << "Migrated #{results.size} tenants in #{total_duration.round(1)}s (#{threads} threads)"
        lines << "  #{succeeded.size} succeeded" if succeeded.any?
        lines << "  #{failed.size} failed: [#{failed.map(&:tenant).join(', ')}]" if failed.any?
        lines << "  #{skipped.size} skipped (up to date)" if skipped.any?
        lines.join("\n")
      end
    end

    CREDENTIAL_KEYS = %i[username password host].freeze

    def initialize(threads: 0, migration_db_config: nil)
      @threads = threads
      @migration_db_config = migration_db_config
      @pool_manager = PoolManager.new
    end

    def run
      start = monotonic_now

      primary_result = migrate_primary

      tenants = Apartment.config.tenants_provider.call
      tenant_results = if @threads > 0
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
      @pool_manager.clear
    end

    private

    def migrate_primary
      tenant_name = Apartment.config.default_tenant || 'public'
      start = monotonic_now

      config = Apartment.adapter.resolve_connection_config(tenant_name)
      migration_config = resolve_migration_db_config
      config = resolve_migration_config(config, migration_config)

      pool = @pool_manager.fetch_or_create('__primary__') { create_pool(config) }
      context = pool.migration_context

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

    def migrate_tenant(tenant)
      start = monotonic_now

      config = Apartment.adapter.resolve_connection_config(tenant)
      migration_config = resolve_migration_db_config
      config = resolve_migration_config(config, migration_config)

      pool_key = "apartment_migrate_#{config['schema_search_path'] || config['database']}"
      pool = @pool_manager.fetch_or_create(pool_key) { create_pool(config) }
      context = pool.migration_context

      unless context.needs_migration?
        return Result.new(
          tenant: tenant, status: :skipped,
          duration: monotonic_now - start, error: nil, versions_run: []
        )
      end

      raw_versions = context.migrate
      versions = Array(raw_versions).map { _1.respond_to?(:version) ? _1.version : _1 }

      Instrumentation.instrument(:migrate_tenant, tenant: tenant, versions: versions)

      Result.new(
        tenant: tenant, status: :success,
        duration: monotonic_now - start, error: nil, versions_run: versions
      )
    rescue StandardError => e
      Result.new(
        tenant: tenant, status: :failed,
        duration: monotonic_now - start, error: e, versions_run: []
      )
    end

    def run_sequential(tenants)
      tenants.map { |tenant| migrate_tenant(tenant) }
    end

    def run_parallel(tenants)
      work_queue = Queue.new
      tenants.each { |t| work_queue << t }
      @threads.times { work_queue << :done }

      results = Concurrent::Array.new

      workers = @threads.times.map do
        Thread.new do
          while (tenant = work_queue.pop) != :done
            results << migrate_tenant(tenant)
          end
        end
      end

      workers.each(&:join)
      results.to_a
    end

    def resolve_migration_db_config
      return nil if @migration_db_config.nil?

      env_name = defined?(Rails) ? Rails.env : 'default_env'
      db_config = ActiveRecord::Base.configurations.configs_for(
        env_name: env_name, name: @migration_db_config.to_s
      )

      unless db_config
        raise(ConfigurationError,
          "No database configuration found for env_name: #{env_name}, name: #{@migration_db_config}")
      end

      db_config.configuration_hash
    end

    def create_pool(config)
      spec_name = "apartment_migrate_#{config['schema_search_path'] || config['database']}"
      db_config = ActiveRecord::DatabaseConfigurations::HashConfig.new(
        defined?(Rails) ? Rails.env : 'default_env',
        spec_name,
        config.transform_keys(&:to_sym)
      )
      handler = ActiveRecord::Base.connection_handler
      handler.establish_connection(db_config)
    end

    # Overlay migration credentials onto a tenant's base connection config.
    # base_config has string keys (from adapter), migration_config has symbol keys
    # (from configuration_hash). We normalize the overlay to string keys.
    def resolve_migration_config(base_config, migration_config)
      return base_config unless migration_config

      overlay = migration_config.slice(*CREDENTIAL_KEYS).compact
      base_config.merge(overlay.transform_keys(&:to_s))
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
