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

      Apartment::Railtie.deactivate_pool_reaper_in_test_env!
    end

    # Insert elevator middleware if configured.
    #
    # Ordered after :load_config_initializers so config/initializers/apartment.rb
    # (the conventional place for Apartment.configure) has already run — a plain
    # railtie initializer runs before it, when Apartment.config is still nil, and
    # would silently insert nothing. Kept before :build_middleware_stack so the
    # insertion lands while the stack is still mutable.
    initializer 'apartment.middleware',
                after: :load_config_initializers,
                before: :build_middleware_stack do |app|
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

    # Map Apartment::TenantNotFound to a 404 so an unknown tenant renders the
    # application's own 404 page when no tenant_not_found_handler is configured.
    # rescue_responses has a non-nil default (:internal_server_error), so a
    # key? check — not ||= — is what skips an app's own explicit mapping.
    #
    # Rails main (post-rails/rails#57483) makes
    # ActionDispatch::ExceptionWrapper.rescue_responses Ractor-safe by freezing
    # the underlying hash and merging the engine config
    # config.action_dispatch.rescue_responses in during action_dispatch.configure.
    # Older Rails has a mutable hash and no engine-config merge. We do both:
    # contribute via engine config (picked up by Rails main + harmless on older
    # Rails) and mutate directly when the hash is still mutable (the
    # only path that works on Rails ≤ 8.1.x).
    initializer 'apartment.rescue_responses', before: 'action_dispatch.configure' do |app|
      require 'action_dispatch'

      # Rails main path: engine config merged + refrozen during action_dispatch.configure.
      app.config.action_dispatch.rescue_responses['Apartment::TenantNotFound'] = :not_found

      # Pre-rails-main path: mutate directly while the hash is still mutable.
      responses = ActionDispatch::ExceptionWrapper.rescue_responses
      unless responses.frozen? || responses.key?('Apartment::TenantNotFound')
        responses['Apartment::TenantNotFound'] = :not_found
      end
    end

    # Backport rails/rails#56902 ("Pass IsolatedExecutionState.context to
    # share_with") to released Rails versions where it has not landed. Prepend
    # Apartment::Patches::LiveTenantPropagation onto ActionController::Live so
    # the patch's process(name) override runs before Rails' own, mirroring
    # Fiber.current.active_support_execution_state onto Thread.current's
    # accessor for the duration of process — Rails' share_with(Thread.current)
    # then finds the right hash and shallow-dups it into the spawned thread's
    # root fiber. All CurrentAttributes propagate, not just apartment's tenant
    # — matching what share_with(context) does on rails main.
    #
    # The patch is a no-op under :thread isolation, and a (redundant, harmless)
    # no-op once #56902 reaches a stable Rails release apartment supports.
    #
    # See docs/designs/rails-boundary-tenancy.md.
    # Module#prepend does not retroactively update the ancestor chains of
    # classes that have already `include`d the target module — so this
    # initializer must run before any controller that includes
    # ActionController::Live is loaded. In normal Rails boot order that's
    # fine: controllers are autoloaded on first request, well after every
    # named initializer has run. A host that loads a Live-including
    # controller from inside config/initializers/*.rb (rare) would miss the
    # prepend; document and move on rather than chaining `before:` ordering
    # that creates a cycle with Rails' implicit declaration-order @after.
    initializer 'apartment.live_tenancy' do
      next unless defined?(ActionController::Base) # skip when action_controller is not in the dependency graph

      require 'action_controller/metal/live'
      require 'apartment/patches/live_tenant_propagation'
      next if ActionController::Live.include?(Apartment::Patches::LiveTenantPropagation)

      ActionController::Live.prepend(Apartment::Patches::LiveTenantPropagation)
    end

    # In test environments, clean up apartment's tenant pools before Rails'
    # fixture setup iterates shards. See docs/designs/v4-test-fixtures-compatibility.md.
    if Rails.env.test?
      ActiveSupport.on_load(:active_record_fixtures) do
        if Apartment.config&.test_fixture_cleanup
          require 'apartment/test_fixtures'
          prepend Apartment::TestFixtures
        end
      end
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

    # Insert elevator middleware after ActionDispatch::Callbacks.
    # In the full stack this places it just before Cookies/Session/Auth.
    # In API mode (where Cookies is absent), Callbacks is still present.
    # Class method for testability.
    def self.insert_elevator_middleware(middleware_stack, elevator_class, **)
      middleware_stack.insert_after(ActionDispatch::Callbacks, elevator_class, **)
    end

    # Whether the Header elevator trust warning should fire. Class method for testability.
    def self.header_trust_warning?(elevator_class, opts)
      # Module#<= returns nil (not false) for unrelated classes, so a bare
      # `&&` would let unrelated elevators slip through as nil — coerce via
      # an explicit guard so non-Header elevators report false.
      return false unless elevator_class <= Apartment::Elevators::Header

      !opts[:trusted]
    end

    # In test environments the reaper is more liability than asset: suites
    # are short, tenant counts low, memory pressure absent, and an eviction
    # mid-example orphans transactional-fixture state. Stop the reaper that
    # Apartment.configure started; a suite that genuinely needs eviction
    # can call Apartment.pool_reaper.start explicitly. Emits :reaper_stopped
    # so an upgrading adopter notices the behavior change without combing
    # release notes.
    #
    # Opt out with `config.reap_in_test = true`: a deployment whose processes
    # can run under Rails.env.test? semantics (and must keep reaping) then needs
    # no boot guard around RAILS_ENV to avoid silently leaking connections.
    def self.deactivate_pool_reaper_in_test_env!
      return unless Rails.env.test?
      return if Apartment.config&.reap_in_test
      return unless Apartment.pool_reaper

      Apartment.pool_reaper.stop
      Apartment::Instrumentation.instrument(:reaper_stopped, reason: :test_env)
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
