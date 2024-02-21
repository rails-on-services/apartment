# frozen_string_literal: true

require 'apartment/tenant'

module Apartment
  module Migrator
    extend self

    # Migrate to latest
    def migrate(database)
      Tenant.switch(database) do
        version = ENV['VERSION'] ? ENV['VERSION'].to_i : nil

        migration_scope_block = ->(migration) { ENV['SCOPE'].blank? || (ENV['SCOPE'] == migration.scope) }

        ActiveRecord::Base.connection.migration_context.migrate(version, &migration_scope_block)
      end
    end

    # Migrate up/down to a specific version
    def run(direction, database, version)
      Tenant.switch(database) do
        ActiveRecord::Base.connection.migration_context.run(direction, version)
      end
    end

    # rollback latest migration `step` number of times
    def rollback(database, step = 1)
      Tenant.switch(database) do
        ActiveRecord::Base.connection.migration_context.rollback(step)
      end
    end
  end
end
