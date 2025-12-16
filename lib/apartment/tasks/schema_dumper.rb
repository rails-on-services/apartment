# frozen_string_literal: true

module Apartment
  module Tasks
    # Handles automatic schema dumping after migrations
    # Respects multi-database configurations (database_tasks, schema_dump settings)
    module SchemaDumper
      class << self
        # Dump schema if enabled in configuration
        # Called after successful migrations
        # Respects both Apartment.auto_dump_schema and Rails' dump_schema_after_migration
        def dump_if_enabled
          return unless Apartment.auto_dump_schema
          return unless rails_dump_schema_enabled?

          db_config = find_schema_dump_config
          return if db_config.nil?

          schema_dump_setting = db_config.configuration_hash[:schema_dump]
          return if schema_dump_setting == false

          Apartment::Tenant.switch(Apartment.default_tenant) do
            dump_schema
            dump_schema_cache if Apartment.auto_dump_schema_cache
          end
        rescue StandardError => e
          # Don't fail the migration if schema dump fails
          puts "[Apartment] Warning: Schema dump failed: #{e.message}"
        end

        # Dump schema cache if enabled in configuration
        def dump_schema_cache_if_enabled
          return unless Apartment.auto_dump_schema_cache

          db_config = find_schema_dump_config
          return if db_config.nil?

          Apartment::Tenant.switch(Apartment.default_tenant) do
            dump_schema_cache
          end
        rescue StandardError => e
          puts "[Apartment] Warning: Schema cache dump failed: #{e.message}"
        end

        private

        # Find the database configuration to use for schema dump
        # Priority: 1) User-configured, 2) database_tasks: true, 3) primary
        #
        # @return [ActiveRecord::DatabaseConfigurations::DatabaseConfig, nil]
        def find_schema_dump_config
          configs = ActiveRecord::Base.configurations.configs_for(env_name: Rails.env)

          # User explicitly configured which connection to use
          if Apartment.schema_dump_connection
            return configs.find { |c| c.name == Apartment.schema_dump_connection.to_s }
          end

          # Find connection with database_tasks: true (non-replica)
          migration_config = configs.find { |c| c.database_tasks? && !c.replica? }
          return migration_config if migration_config

          # Fallback to primary
          configs.find { |c| c.name == 'primary' }
        end

        # Invoke Rails schema dump task
        def dump_schema
          if task_defined?('db:schema:dump')
            puts '[Apartment] Dumping schema from public schema...'
            Rake::Task['db:schema:dump'].reenable
            Rake::Task['db:schema:dump'].invoke
            puts '[Apartment] Schema dump completed.'
          else
            puts '[Apartment] Warning: db:schema:dump task not found'
          end
        end

        # Invoke Rails schema cache dump task
        def dump_schema_cache
          if task_defined?('db:schema:cache:dump')
            puts '[Apartment] Dumping schema cache from public schema...'
            Rake::Task['db:schema:cache:dump'].reenable
            Rake::Task['db:schema:cache:dump'].invoke
            puts '[Apartment] Schema cache dump completed.'
          else
            puts '[Apartment] Warning: db:schema:cache:dump task not found'
          end
        end

        # Check if the rake task exists - we don't call load_tasks because
        # if we're being invoked from a rake task, tasks are already loaded.
        # Calling load_tasks would re-trigger apartment task enhancements.
        def task_defined?(task_name)
          Rake::Task.task_defined?(task_name)
        end

        # Check if Rails' dump_schema_after_migration is enabled
        # This respects the global Rails setting for schema dumping
        def rails_dump_schema_enabled?
          return true unless ActiveRecord::Base.respond_to?(:dump_schema_after_migration)

          ActiveRecord::Base.dump_schema_after_migration
        end
      end
    end
  end
end
