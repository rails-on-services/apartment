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
        Apartment::Tenant.init
      rescue ActiveRecord::NoDatabaseError
        warn '[Apartment] Database not found during init — skipping. Run db:create first.'
      end
    end

    # Insert elevator middleware if configured.
    initializer 'apartment.middleware' do |app|
      next unless Apartment.config&.elevator

      elevator_class = Apartment::Railtie.resolve_elevator_class(Apartment.config.elevator)
      options = Apartment.config.elevator_options || {}
      app.middleware.use(elevator_class, *options.values)
    end

    rake_tasks do
      load File.expand_path('tasks/v4.rake', __dir__)
    end

    # Resolve an elevator symbol to its class. Class method for testability.
    def self.resolve_elevator_class(elevator)
      class_name = "Apartment::Elevators::#{elevator.to_s.camelize}"
      require("apartment/elevators/#{elevator}")
      class_name.constantize
    rescue NameError, LoadError => e
      available = Dir[File.join(__dir__, 'elevators', '*.rb')]
        .map { |f| File.basename(f, '.rb') }
        .reject { |n| n == 'generic' }
      raise(Apartment::ConfigurationError,
            "Unknown elevator '#{elevator}': #{e.message}. " \
            "Available elevators: #{available.join(', ')}")
    end
  end
end
