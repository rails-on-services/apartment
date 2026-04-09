# frozen_string_literal: true

require 'rails'

module Apartment
  class Railtie < Rails::Railtie
    # After all initializers run: wire up Apartment if configured.
    config.after_initialize do
      next unless Apartment.config

      # v4 requires fiber isolation for correct CurrentAttributes propagation.
      if defined?(ActiveSupport::IsolatedExecutionState) &&
         ActiveSupport::IsolatedExecutionState.isolation_level == :thread
        warn '[Apartment] WARNING: ActiveSupport isolation_level is :thread. ' \
             'Apartment v4 requires :fiber for correct CurrentAttributes propagation. ' \
             'Set config.active_support.isolation_level = :fiber in your application config.'
      end

      begin
        Apartment.activate!
        Apartment.activate_sql_query_tags!
        Apartment::Tenant.init

        # Apply schema dumper patch for Rails 8.1+ (public. prefix stripping)
        require('apartment/schema_dumper_patch')
        Apartment::SchemaDumperPatch.apply!
      rescue ActiveRecord::NoDatabaseError
        warn '[Apartment] Database not found during init — skipping. Run db:create first.'
      end
    end

    # Insert elevator middleware if configured.
    initializer 'apartment.middleware' do |app|
      next unless Apartment.config&.elevator

      elevator_class = Apartment::Railtie.resolve_elevator_class(Apartment.config.elevator)
      opts = Apartment.config.elevator_options || {}

      if Apartment::Railtie.header_trust_warning?(elevator_class, opts)
        warn <<~WARNING
          [Apartment] WARNING: Header elevator with trusted: false.
          Header-based tenant resolution trusts the client to provide the correct tenant.
          Only use this when the header is injected by trusted infrastructure (CDN, reverse proxy)
          that strips client-supplied values.
        WARNING
      end

      Apartment::Railtie.insert_elevator_middleware(app.middleware, elevator_class, **opts)
    end

    rake_tasks do
      load File.expand_path('tasks/v4.rake', __dir__)

      # Enhance db:migrate:DBNAME to also run apartment:migrate.
      # configs_for and task_defined? are pure config/rake lookups — no DB
      # connection is made, so no rescue is needed.
      primary_db_name = ActiveRecord::Base.configurations
        .configs_for(env_name: Rails.env)
        .find { |c| c.name == 'primary' }
        &.name || 'primary'

      if Rake::Task.task_defined?("db:migrate:#{primary_db_name}")
        Rake::Task["db:migrate:#{primary_db_name}"].enhance do
          Rake::Task['apartment:migrate'].invoke if Rake::Task.task_defined?('apartment:migrate')
        end
      end
    end

    # Insert elevator middleware before ActionDispatch::Cookies.
    # This ensures tenant context is established before sessions, authentication,
    # or anything else that might query the database.
    # Class method for testability.
    def self.insert_elevator_middleware(middleware_stack, elevator_class, **)
      middleware_stack.insert_before(ActionDispatch::Cookies, elevator_class, **)
    end

    # Whether the Header elevator trust warning should fire. Class method for testability.
    def self.header_trust_warning?(elevator_class, opts)
      elevator_class <= Apartment::Elevators::Header && !opts[:trusted]
    end

    # Resolve an elevator symbol/string to its class. Class method for testability.
    # Accepts a Class directly (pass-through) or a symbol/string for lookup.
    def self.resolve_elevator_class(elevator)
      return elevator if elevator.is_a?(Class)

      class_name = "Apartment::Elevators::#{elevator.to_s.camelize}"
      require("apartment/elevators/#{elevator}")
      class_name.constantize
    rescue NameError, LoadError => e
      available = Dir[File.join(__dir__, 'elevators', '*.rb')]
        .filter_map { |f| File.basename(f, '.rb').then { |name| name unless name == 'generic' } }
      raise(Apartment::ConfigurationError,
            "Unknown elevator '#{elevator}': #{e.message}. " \
            "Available elevators: #{available.join(', ')}")
    end
  end
end
