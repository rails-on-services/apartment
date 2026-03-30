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
      opts = Apartment.config.elevator_options || {}

      if elevator_class <= Apartment::Elevators::Header && !opts[:trusted]
        warn <<~WARNING
          [Apartment] WARNING: Header elevator with trusted: false.
          Header-based tenant resolution trusts the client to provide the correct tenant.
          Only use this when the header is injected by trusted infrastructure (CDN, reverse proxy)
          that strips client-supplied values.
        WARNING
      end

      app.middleware.use(elevator_class, **opts)
    end

    rake_tasks do
      load File.expand_path('tasks/v4.rake', __dir__)
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
