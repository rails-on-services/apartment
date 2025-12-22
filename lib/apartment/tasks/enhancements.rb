# frozen_string_literal: true

# Require this file to append Apartment rake tasks to ActiveRecord db rake tasks
# Enabled by default in the initializer
#
# ## Multi-Database Support (Rails 7+)
#
# When a Rails app has multiple databases configured in database.yml, Rails creates
# namespaced rake tasks like `db:migrate:primary`, `db:rollback:primary`, etc.
# This enhancer automatically detects databases with `database_tasks: true` and
# enhances their namespaced tasks to also run the corresponding apartment task.
#
# Example: Running `rails db:rollback:primary` will also invoke `apartment:rollback`
# to rollback all tenant schemas.

module Apartment
  class RakeTaskEnhancer
    module TASKS
      ENHANCE_BEFORE = %w[db:drop].freeze
      ENHANCE_AFTER  = %w[db:migrate db:rollback db:migrate:up db:migrate:down db:migrate:redo db:seed].freeze

      # Base tasks that have namespaced variants in multi-database setups
      # db:seed is excluded because Rails doesn't create db:seed:primary
      NAMESPACED_AFTER = %w[db:migrate db:rollback db:migrate:up db:migrate:down db:migrate:redo].freeze
      freeze
    end

    # This is a bit convoluted, but helps solve problems when using Apartment within an engine
    # See spec/integration/use_within_an_engine.rb

    class << self
      def enhance!
        return unless should_enhance?

        enhance_base_tasks!
        enhance_namespaced_tasks!
      end

      def should_enhance?
        Apartment.db_migrate_tenants
      end

      private

      # Enhance standard db:* tasks (backward compatible behavior)
      def enhance_base_tasks!
        TASKS::ENHANCE_BEFORE.each do |name|
          enhance_task_before(name)
        end

        TASKS::ENHANCE_AFTER.each do |name|
          enhance_task_after(name)
        end
      end

      # Enhance namespaced db:*:database_name tasks for multi-database setups
      # Maps namespaced tasks to base apartment tasks:
      #   db:migrate:primary    -> apartment:migrate
      #   db:rollback:primary   -> apartment:rollback
      #   db:migrate:up:primary -> apartment:migrate:up
      def enhance_namespaced_tasks!
        database_names_with_tasks.each do |db_name|
          TASKS::NAMESPACED_AFTER.each do |base_task|
            namespaced_task = "#{base_task}:#{db_name}"
            next unless task_defined?(namespaced_task)

            apartment_task = base_task.sub('db:', 'apartment:')
            enhance_namespaced_task_after(namespaced_task, apartment_task)
          end
        end
      end

      def enhance_task_before(name)
        return unless task_defined?(name)

        task = Rake::Task[name]
        task.enhance([inserted_task_name(task)])
      end

      def enhance_task_after(name)
        return unless task_defined?(name)

        task = Rake::Task[name]
        task.enhance do
          Rake::Task[inserted_task_name(task)].invoke
        end
      end

      def enhance_namespaced_task_after(namespaced_task_name, apartment_task_name)
        Rake::Task[namespaced_task_name].enhance do
          Rake::Task[apartment_task_name].invoke
        end
      end

      def inserted_task_name(task)
        task.name.sub('db:', 'apartment:')
      end

      def task_defined?(name)
        Rake::Task.task_defined?(name)
      end

      # Returns database names that have database_tasks enabled and are not replicas.
      # These are the databases for which Rails creates namespaced rake tasks.
      #
      # @return [Array<String>] database names (e.g., ['primary', 'secondary'])
      def database_names_with_tasks
        return [] unless defined?(Rails) && Rails.respond_to?(:env)

        configs = ActiveRecord::Base.configurations.configs_for(env_name: Rails.env)
        configs
          .select { |c| c.database_tasks? && !c.replica? }
          .map(&:name)
      rescue StandardError
        # Fail gracefully if configurations unavailable (e.g., during early boot)
        []
      end
    end
  end
end

Apartment::RakeTaskEnhancer.enhance!
