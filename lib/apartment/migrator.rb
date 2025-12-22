# frozen_string_literal: true

require 'apartment/tenant'

module Apartment
  module Migrator
    module_function

    # Migrate to latest
    def migrate(database)
      # Pin a connection for the entire migration to ensure Tenant.switch
      # sets search_path on the same connection used by migration_context.
      # Without this, connection pool may return different connections
      # for the switch vs the actual migration operations.
      ActiveRecord::Base.connection_pool.with_connection do
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
    end

    # Migrate up/down to a specific version
    def run(direction, database, version)
      ActiveRecord::Base.connection_pool.with_connection do
        Tenant.switch(database) do
          if ActiveRecord.version >= Gem::Version.new('7.2.0')
            ActiveRecord::Base.connection_pool.migration_context.run(direction, version)
          else
            ActiveRecord::Base.connection.migration_context.run(direction, version)
          end
        end
      end
    end

    # rollback latest migration `step` number of times
    def rollback(database, step = 1)
      ActiveRecord::Base.connection_pool.with_connection do
        Tenant.switch(database) do
          if ActiveRecord.version >= Gem::Version.new('7.2.0')
            ActiveRecord::Base.connection_pool.migration_context.rollback(step)
          else
            ActiveRecord::Base.connection.migration_context.rollback(step)
          end
        end
      end
    end
  end
end
