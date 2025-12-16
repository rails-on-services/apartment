# frozen_string_literal: true

module Apartment
  module Tasks
    # Handles automatic schema.rb dumping after tenant migrations.
    #
    # ## Problem Context
    #
    # After running `rails db:migrate`, Rails dumps schema.rb to capture the
    # current database structure. With Apartment, tenant migrations modify
    # individual schemas but the canonical structure lives in the public/default
    # schema. Without explicit handling, schema.rb could be dumped from the
    # last-migrated tenant schema instead of the authoritative public schema.
    #
    # ## Why This Approach
    #
    # We switch to the default tenant before dumping to ensure schema.rb
    # reflects the public schema structure. This is correct because:
    #
    # 1. All tenant schemas are created from the same schema.rb
    # 2. The public schema is the source of truth for structure
    # 3. Tenant-specific data differences don't affect schema structure
    #
    # ## Rails Convention Compliance
    #
    # We respect several Rails configurations rather than inventing our own:
    #
    # - `config.active_record.dump_schema_after_migration`: Global toggle
    # - `database_tasks: true/false`: Per-database migration responsibility
    # - `replica: true`: Excludes read replicas from schema operations
    # - `schema_dump: false`: Per-database schema dump toggle
    #
    # ## Gotchas
    #
    # - Schema dump failures are logged but don't fail the migration. This
    #   prevents a secondary concern from blocking critical migrations.
    # - Multi-database setups must mark one connection with `database_tasks: true`
    #   to indicate which database owns schema management.
    # - Don't call `Rails.application.load_tasks` here; if invoked from a rake
    #   task, it re-triggers apartment enhancements causing recursion.
    module SchemaDumper
      class << self
        # Entry point called after successful migrations. Checks all relevant
        # Rails settings before attempting dump.
        def dump_if_enabled
          return unless rails_dump_schema_enabled?

          db_config = find_schema_dump_config
          return if db_config.nil?

          schema_dump_setting = db_config.configuration_hash[:schema_dump]
          return if schema_dump_setting == false

          Apartment::Tenant.switch(Apartment.default_tenant) do
            dump_schema
          end
        rescue StandardError => e
          # Log but don't fail - schema dump is secondary to migration success
          Rails.logger.warn("[Apartment] Schema dump failed: #{e.message}")
        end

        private

        # Finds the database configuration responsible for schema management.
        # Rails 6.1+ multi-database setups use `database_tasks: true` to mark
        # the primary migration database. Falls back to 'primary' named config.
        def find_schema_dump_config
          configs = ActiveRecord::Base.configurations.configs_for(env_name: Rails.env)

          migration_config = configs.find { |c| c.database_tasks? && !c.replica? }
          return migration_config if migration_config

          configs.find { |c| c.name == 'primary' }
        end

        # Invokes the standard Rails schema dump task. We reenable first
        # because Rake tasks can only run once per session by default.
        def dump_schema
          if task_defined?('db:schema:dump')
            Rails.logger.info('[Apartment] Dumping schema from public schema...')
            Rake::Task['db:schema:dump'].reenable
            Rake::Task['db:schema:dump'].invoke
            Rails.logger.info('[Apartment] Schema dump completed.')
          else
            Rails.logger.warn('[Apartment] db:schema:dump task not found')
          end
        end

        # Safe task existence check. Avoids load_tasks which would cause
        # recursive enhancement loading when called from apartment rake tasks.
        def task_defined?(task_name)
          Rake::Task.task_defined?(task_name)
        end

        # Checks Rails' global schema dump setting. Older Rails versions
        # may not have this method, so we default to enabled.
        def rails_dump_schema_enabled?
          return true unless ActiveRecord::Base.respond_to?(:dump_schema_after_migration)

          ActiveRecord::Base.dump_schema_after_migration
        end
      end
    end
  end
end
