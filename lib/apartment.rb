# frozen_string_literal: true

require 'zeitwerk'
require 'active_support'
require 'active_support/current_attributes'
require 'concurrent'

# Set up Zeitwerk autoloader for the Apartment namespace.
# Must happen before requiring files that define constants in the Apartment module.
loader = Zeitwerk::Loader.for_gem(warn_on_extra_files: false)

# errors.rb defines multiple constants (not a single Errors class),
# so it must be loaded explicitly rather than autoloaded.
loader.ignore("#{__dir__}/apartment/errors.rb")

# Railtie is loaded explicitly via require_relative at the bottom of this file.
loader.ignore("#{__dir__}/apartment/railtie.rb")

# Rake tasks are loaded by the Railtie, not autoloaded.
loader.ignore("#{__dir__}/apartment/tasks")

# CLI is loaded explicitly (require 'apartment/cli') by rake tasks and the binstub.
# Ignoring cli.rb avoids Zeitwerk mapping it to Apartment::Cli (wrong casing).
# Ignoring cli/ avoids autoloading Thor subcommands before Thor is required.
loader.ignore("#{__dir__}/apartment/cli.rb")
loader.ignore("#{__dir__}/apartment/cli")

# Collapse concerns/ so Zeitwerk maps lib/apartment/concerns/model.rb
# to Apartment::Model (not Apartment::Concerns::Model). Mirrors the
# Rails convention for app/models/concerns/.
loader.collapse("#{__dir__}/apartment/concerns")

loader.setup

require_relative 'apartment/errors'
require_relative 'apartment/tenant_validator'

module Apartment # rubocop:disable Metrics/ModuleLength
  # Rack env key used to carry the resolved tenant across execution boundaries
  # (notably the OS thread spawned by ActionController::Live#process). The
  # elevator writes this; Apartment::LiveTenancy reads it.
  ENV_TENANT_KEY = 'apartment.tenant'

  class << self # rubocop:disable Metrics/ClassLength
    attr_reader :config, :pool_manager, :pool_reaper
    attr_writer :adapter

    # Lazy-loading adapter. Built on first access via build_adapter.
    # Can be set manually (e.g., in tests) via Apartment.adapter=.
    def adapter
      @adapter ||= build_adapter
    end

    # An always-valid validator, used when config.tenant_validator is false.
    ALWAYS_VALID_TENANT = ->(_name) { true }

    # Guards lazy construction of the built-in validator. A constant (not an
    # ivar) so it survives clear_config, which nils @built_in_tenant_validator.
    BUILT_IN_VALIDATOR_MUTEX = Mutex.new

    # Resolves config.tenant_validator to a callable: false -> always valid,
    # nil -> the process's built-in TenantValidator (memoized), a callable ->
    # itself.
    def tenant_validator
      case (configured = @config&.tenant_validator)
      when false then ALWAYS_VALID_TENANT
      when nil then built_in_tenant_validator
      else configured
      end
    end

    # Registry of models that declared pin_tenant.
    # Uses Concurrent::Set for thread safety (Zeitwerk autoload in threaded servers).
    def pinned_models
      @pinned_models ||= Concurrent::Set.new
    end

    def register_pinned_model(klass)
      pinned_models.add(klass)
    end

    # Check if a class (or any of its ancestors) is a pinned model.
    # Delegates to the class's own apartment_pinned? (defined by the
    # Apartment::Model concern). Falls back to registry lookup for
    # models registered via the excluded_models shim without the concern.
    def pinned_model?(klass)
      if klass.respond_to?(:apartment_pinned?)
        klass.apartment_pinned?
      else
        klass.ancestors.any? { |a| a.is_a?(Class) && pinned_models.include?(a) }
      end
    end

    def activated?
      @activated == true
    end

    # Returns the current tenant list. Single resolver used by Tenant.each,
    # Migrator, SchemaCache, and the CLI commands. Honors the per-block
    # override set by Tenant.with_tenants_provider / with_tenants when present;
    # otherwise resolves through @config.tenants_provider.
    #
    # The override (or the configured provider) may itself be a callable, in
    # which case it is invoked on every access. Whatever the source, the
    # resolved value must respond to :each.
    def tenant_names
      raise(ConfigurationError, 'Apartment not configured. Call Apartment.configure first.') unless @config

      override = Current.tenant_override
      source = override || @config.tenants_provider
      result = source.respond_to?(:call) ? source.call : source

      unless result.respond_to?(:each)
        source_label = override ? 'tenant_override' : 'tenants_provider'
        raise(ConfigurationError,
              "#{source_label} must return an Enumerable, got #{result.class}")
      end
      result
    end

    # v3 compatibility: Apartment.excluded_models returns the excluded models list.
    # Deprecated in v4 (use Apartment::Model + pin_tenant instead).
    def excluded_models
      raise(ConfigurationError, 'Apartment not configured. Call Apartment.configure first.') unless @config

      @config.excluded_models
    end

    def process_pinned_model(klass)
      unless adapter
        warn "[Apartment] Cannot process pinned model #{klass.name || klass.inspect}: " \
             'adapter not initialized. Model registered but unprocessed.'
        return
      end
      adapter.process_pinned_model(klass)
    end

    # Configure Apartment v4. Yields a Config instance, validates it,
    # and prepares the module for use.
    #
    #   Apartment.configure do |config|
    #     config.tenant_strategy = :schema
    #     config.tenants_provider = -> { Tenant.pluck(:name) }
    #   end
    #
    def configure
      raise(ConfigurationError, 'Apartment.configure requires a block') unless block_given?

      new_config = Config.new
      yield(new_config)
      new_config.apply_defaults!
      new_config.validate!
      new_config.freeze!

      # Validation passed — tear down old state and swap in new.
      teardown_old_state
      @built_in_tenant_validator&.shutdown
      @built_in_tenant_validator = nil
      @config = new_config
      @pool_manager = PoolManager.new
      @pool_reaper = PoolReaper.new(
        pool_manager: @pool_manager,
        interval: new_config.pool_idle_timeout,
        idle_timeout: new_config.pool_idle_timeout,
        max_total: new_config.max_total_connections,
        default_tenant: new_config.default_tenant,
        shard_key_prefix: new_config.shard_key_prefix
      )
      @pool_reaper.start
      @config
    end

    # Reset all configuration and stop background tasks.
    def clear_config
      teardown_old_state
      # Restore (un-qualify) pinned models, but keep them registered. pin_tenant
      # runs once when a model's class body loads and never re-runs, so the
      # registry is the only record of which models are pinned. Discarding it
      # would strand every pinned model unprocessed after the next configure.
      # The registry is bounded in production (pinned models are named
      # constants); a test process that pins anonymous classes accumulates them
      # here — acceptable, but count-sensitive specs must isolate it themselves.
      @pinned_models&.each { |klass| klass.apartment_restore! if klass.respond_to?(:apartment_restore!) }
      @built_in_tenant_validator&.shutdown
      @built_in_tenant_validator = nil
      @config = nil
      @pool_manager = nil
      @pool_reaper = nil
      @activated = false
    end

    # Activate the ConnectionHandling patch on ActiveRecord::Base.
    # Idempotent — prepend on an already-prepended module is a no-op.
    def activate!
      require_relative('apartment/patches/connection_handling')
      ActiveRecord::Base.singleton_class.prepend(Patches::ConnectionHandling)
      @activated = true
    end

    # Register a :tenant tag with ActiveRecord::QueryLogs so SQL queries
    # include a /* tenant='name' */ comment. No-op when sql_query_tags is
    # false or ActiveRecord::QueryLogs is not available.
    def activate_sql_query_tags!
      return unless @config&.sql_query_tags
      return unless defined?(ActiveRecord::QueryLogs)
      return if ActiveRecord::QueryLogs.tags.include?(:tenant)

      ActiveRecord::QueryLogs.taggings = ActiveRecord::QueryLogs.taggings.merge(
        tenant: -> { Apartment::Current.tenant }
      )
      ActiveRecord::QueryLogs.tags = ActiveRecord::QueryLogs.tags + [:tenant]
    end

    # Deregister a single tenant's shard from AR's ConnectionHandler.
    # Safe to call when AR is not loaded or config is not set (no-op).
    # Used by PoolReaper eviction, AbstractAdapter#drop, and teardown.
    def deregister_shard(pool_key)
      return unless @config && defined?(ActiveRecord::Base)

      _, separator, role_str = pool_key.to_s.rpartition(':')
      role = separator.empty? || role_str.empty? ? ActiveRecord.writing_role : role_str.to_sym

      shard_key = :"#{@config.shard_key_prefix}_#{pool_key}"
      ActiveRecord::Base.connection_handler.remove_connection_pool(
        'ActiveRecord::Base',
        role: role,
        shard: shard_key
      )
    rescue StandardError => e
      warn "[Apartment] Failed to deregister AR pool for #{pool_key}: #{e.class}: #{e.message}"
    end

    # Deregister all tenant pools from AR's ConnectionHandler and clear the
    # pool manager cache. Pools rebuild lazily on the next +connection_pool+
    # call.
    #
    # Execution context (+Apartment::Current+: tenant, tenant_override, etc.)
    # is left untouched — pool lifecycle and tenant context are separate
    # concerns. A caller that also wants to drop tenant context resets it
    # explicitly via +Apartment::Tenant.reset+.
    #
    # Called automatically by +Apartment::TestFixtures+ before Rails' fixture
    # setup iterates shards. Can also be called manually in custom test
    # harnesses that cycle tenant pools between examples.
    #
    # @return [void]
    # @see Apartment::TestFixtures
    def reset_tenant_pools!
      guard_pinned_pools_during_fixtures!
      deregister_all_tenant_pools
      @pool_manager&.clear
    end

    private

    # Double-checked locking: the common path (already built) skips the mutex;
    # concurrent first callers serialize so exactly one validator is built.
    # TenantValidator.new subscribes to ActiveSupport::Notifications, so a
    # discarded duplicate would leak its subscription.
    def built_in_tenant_validator
      @built_in_tenant_validator ||
        BUILT_IN_VALIDATOR_MUTEX.synchronize { @built_in_tenant_validator ||= TenantValidator.new }
    end

    # Safely tear down old state. Stops the reaper first (so it doesn't
    # evict mid-cleanup), then deregisters tenant pools from AR's
    # ConnectionHandler, then clears the pool manager.
    def teardown_old_state
      begin
        @pool_reaper&.stop
      rescue StandardError => e
        warn "[Apartment] PoolReaper.stop failed during teardown: #{e.class}: #{e.message}"
      end
      deregister_all_tenant_pools
      @pool_manager&.clear
      @adapter = nil
    end

    # Refuse to discard tenant pools while Rails' transactional fixtures own
    # them. The recreated pool would have a fresh object identity that the
    # fixture transaction never enrolled, causing silent test pollution.
    # Test-env-scoped via +Rails.env.test?+ so production keeps the existing
    # semantics; reuses the same +@pinned_connection+ primitive the reaper
    # already reads. See docs/designs/fixture-pool-lifecycle.md.
    def guard_pinned_pools_during_fixtures!
      return unless rails_test_env?
      return unless @pool_manager

      @pool_manager.each_pair do |tenant_key, pool|
        next unless Apartment::PoolReaper.pool_pinned?(pool)

        raise(Apartment::FixtureLifecycleViolation, tenant_key)
      end
    end

    def rails_test_env?
      return false unless defined?(Rails) && Rails.respond_to?(:env)

      env = Rails.env
      env.respond_to?(:test?) ? env.test? : env.to_s == 'test'
    end

    def deregister_all_tenant_pools
      return unless @pool_manager

      @pool_manager.stats[:tenants]&.each do |tenant_key|
        deregister_shard(tenant_key)
      end
    end

    # Factory: resolve the correct adapter class based on strategy and database adapter.
    def build_adapter
      raise(ConfigurationError, 'Apartment not configured. Call Apartment.configure first.') unless @config

      strategy = config.tenant_strategy
      db_adapter = detect_database_adapter

      klass = case strategy
              when :schema
                require_relative('apartment/adapters/postgresql_schema_adapter')
                Adapters::PostgresqlSchemaAdapter
              when :database_name
                case db_adapter
                when /postgresql/, /postgis/
                  require_relative('apartment/adapters/postgresql_database_adapter')
                  Adapters::PostgresqlDatabaseAdapter
                when /mysql2/
                  require_relative('apartment/adapters/mysql2_adapter')
                  Adapters::Mysql2Adapter
                when /trilogy/
                  require_relative('apartment/adapters/trilogy_adapter')
                  Adapters::TrilogyAdapter
                when /sqlite/
                  require_relative('apartment/adapters/sqlite3_adapter')
                  Adapters::Sqlite3Adapter
                else
                  raise(AdapterNotFound, "No adapter for database: #{db_adapter}")
                end
              else
                raise(AdapterNotFound, "Strategy #{strategy} not yet implemented")
              end

      klass.new(ActiveRecord::Base.connection_db_config.configuration_hash)
    end

    def detect_database_adapter
      ActiveRecord::Base.connection_db_config.adapter
    end
  end
end

# Load Railtie when Rails is present (standard gem convention).
# Railtie is Zeitwerk-ignored — this explicit require is the only load path.
require_relative 'apartment/railtie' if defined?(Rails::Railtie)
