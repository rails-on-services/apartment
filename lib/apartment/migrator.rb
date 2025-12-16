# frozen_string_literal: true

require 'apartment/tenant'

module Apartment
  module Migrator
    module_function

    # Migrate to latest
    def migrate(database)
      Tenant.switch(database) do
        version = ENV['VERSION']&.to_i

        migration_scope_block = ->(migration) { ENV['SCOPE'].blank? || (ENV['SCOPE'] == migration.scope) }

        if ActiveRecord.version >= Gem::Version.new('7.2.0')
          ActiveRecord::Base.connection_pool.migration_context.migrate(version, &migration_scope_block)
        else
          ActiveRecord::Base.connection.migration_context.migrate(version, &migration_scope_block)
        end
      end
    end

    # Migrate up/down to a specific version
    def run(direction, database, version)
      Tenant.switch(database) do
        if ActiveRecord.version >= Gem::Version.new('7.2.0')
          ActiveRecord::Base.connection_pool.migration_context.run(direction, version)
        else
          ActiveRecord::Base.connection.migration_context.run(direction, version)
        end
      end
    end

    # rollback latest migration `step` number of times
    def rollback(database, step = 1)
      Tenant.switch(database) do
        if ActiveRecord.version >= Gem::Version.new('7.2.0')
          ActiveRecord::Base.connection_pool.migration_context.rollback(step)
        else
          ActiveRecord::Base.connection.migration_context.rollback(step)
        end
      end
    end

    # Rollback all migrations after a specific version
    # This ensures consistent state across all schemas when used with consistent_rollback
    #
    # @param database [String] tenant/schema name
    # @param target_version [String, Integer] version to rollback to (migrations after this will be reversed)
    # @return [Array<Integer>] versions that were rolled back
    def rollback_to_version(database, target_version)
      Tenant.switch(database) do
        connection = ActiveRecord::Base.connection
        quoted_version = connection.quote(target_version.to_s)

        # Find all migrations applied after the target version
        migrations_to_rollback = connection.select_values(
          "SELECT version FROM schema_migrations WHERE version > #{quoted_version} ORDER BY version DESC"
        ).map(&:to_i)

        return [] if migrations_to_rollback.empty?

        # Get migration context for running down migrations
        ctx = if ActiveRecord.version >= Gem::Version.new('7.2.0')
                ActiveRecord::Base.connection_pool.migration_context
              else
                ActiveRecord::Base.connection.migration_context
              end

        # Roll back each migration in reverse order
        migrations_to_rollback.each do |version|
          ctx.run(:down, version)
        end

        migrations_to_rollback
      end
    end
  end
end
