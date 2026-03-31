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

    private

    # Overlay migration credentials onto a tenant's base connection config.
    # base_config has string keys (from adapter), migration_config has symbol keys
    # (from configuration_hash). We normalize the overlay to string keys.
    def resolve_migration_config(base_config, migration_config)
      return base_config unless migration_config

      overlay = migration_config.slice(*CREDENTIAL_KEYS).compact
      base_config.merge(overlay.transform_keys(&:to_s))
    end
  end
end
