# frozen_string_literal: true

require 'thor'

module Apartment
  class CLI < Thor
    class Migrations < Thor
      def self.exit_on_failure? = true

      desc 'migrate [TENANT]', 'Run migrations for tenants'
      long_desc <<~DESC
        Without arguments, migrates all tenants (primary DB first, then tenants
        from tenants_provider). With a TENANT argument, migrates only that tenant.

        Uses Apartment::Migrator for both paths, preserving RBAC role wrapping,
        advisory lock management, and instrumentation.
      DESC
      # Thor :numeric handles large integers (e.g. 20260401000000 timestamps) correctly.
      method_option :version, type: :numeric, desc: 'Target migration version (also reads ENV VERSION)'
      method_option :threads, type: :numeric, desc: 'Override parallel_migration_threads from config'
      def migrate(tenant = nil)
        require('apartment/migrator')

        if tenant
          migrate_single(tenant)
        else
          migrate_all
        end
      end

      desc 'rollback [TENANT]', 'Rollback migrations for tenants'
      long_desc <<~DESC
        Without arguments, rolls back all tenants sequentially.
        With a TENANT argument, rolls back only that tenant.
      DESC
      method_option :step, type: :numeric, default: 1, desc: 'Number of steps to rollback'
      def rollback(tenant = nil)
        if tenant
          rollback_single(tenant)
        else
          rollback_all
        end
      end

      private

      def migrate_single(tenant)
        migrator = Apartment::Migrator.new(version: resolve_version)
        result = migrator.migrate_one(tenant)
        if result.status == :failed
          raise(Thor::Error, "Migration failed for #{tenant}: #{result.error&.class}: #{result.error&.message}")
        end

        say("Migrated tenant: #{tenant} (#{result.status}, #{result.duration.round(2)}s)")
      end

      def migrate_all
        threads = options[:threads] || Apartment.config.parallel_migration_threads
        migrator = Apartment::Migrator.new(threads: threads, version: resolve_version)
        result = migrator.run
        say(result.summary)

        trigger_schema_dump if result.success?
        raise(Thor::Error, "Migration failed for #{result.failed.size} tenant(s)") unless result.success?
      end

      def rollback_single(tenant)
        step = options[:step]
        say("Rolling back tenant: #{tenant} (#{step} step(s))")
        Apartment::Tenant.switch(tenant) do
          ActiveRecord::Base.connection_pool.migration_context.rollback(step)
        end
        say('  done')
      end

      def rollback_all
        step = options[:step]
        tenants = Apartment.config.tenants_provider.call
        failed = []
        tenants.each do |t|
          say("Rolling back tenant: #{t} (#{step} step(s))")
          Apartment::Tenant.switch(t) do
            ActiveRecord::Base.connection_pool.migration_context.rollback(step)
          end
          say('  done')
        rescue StandardError => e
          warn("  FAILED: #{e.message}")
          failed << t
        end
        return if failed.empty?

        raise(Thor::Error, "Rollback failed for #{failed.size} tenant(s): #{failed.join(', ')}")
      end

      def resolve_version
        v = options[:version] || ENV['VERSION']&.to_i
        v&.zero? ? nil : v
      end

      def trigger_schema_dump
        return unless defined?(ActiveRecord) && ActiveRecord.dump_schema_after_migration
        return unless defined?(Rake::Task) && Rake::Task.task_defined?('db:schema:dump')

        Rake::Task['db:schema:dump'].invoke
      end
    end
  end
end
