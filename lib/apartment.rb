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

module Apartment # rubocop:disable Metrics/ModuleLength
  class << self
    attr_reader :config, :pool_manager, :pool_reaper
    attr_writer :adapter

    # Lazy-loading adapter. Built on first access via build_adapter.
    # Can be set manually (e.g., in tests) via Apartment.adapter=.
    def adapter
      @adapter ||= build_adapter
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
    # Used by ConnectionHandling to skip tenant pool routing.
    def pinned_model?(klass)
      klass.ancestors.any? { |a| a.is_a?(Class) && pinned_models.include?(a) }
    end

    def activated?
      @activated == true
    end

    # v3 compatibility: Apartment.tenant_names returns the current tenant list.
    # Delegates to config.tenants_provider.call.
    def tenant_names
      raise(ConfigurationError, 'Apartment not configured. Call Apartment.configure first.') unless @config

      @config.tenants_provider.call
    end

    # v3 compatibility: Apartment.excluded_models returns the excluded models list.
    # Deprecated in v4 (use Apartment::Model + pin_tenant instead).
    def excluded_models
      raise(ConfigurationError, 'Apartment not configured. Call Apartment.configure first.') unless @config

      @config.excluded_models
    end

    def process_pinned_model(klass)
      adapter&.process_pinned_model(klass)
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
      new_config.validate!
      new_config.freeze!

      # Validation passed — tear down old state and swap in new.
      teardown_old_state
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
      @pinned_models&.each { |klass| restore_pinned_model(klass) }
      @config = nil
      @pool_manager = nil
      @pool_reaper = nil
      @pinned_models = nil
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

    private

    # Undo table name qualification and remove tracking ivars from a pinned model.
    # Convention path: restore original prefix so reset_table_name recomputes.
    # Explicit path: restore the original table_name that was overwritten.
    # nil path: separate-pool models (establish_connection only, no table name changes).
    def restore_pinned_model(klass)
      return unless klass.instance_variable_defined?(:@apartment_pinned_processed)

      case klass.instance_variable_get(:@apartment_qualification_path)
      when :convention
        original_prefix = klass.instance_variable_get(:@apartment_original_table_name_prefix) || ''
        klass.table_name_prefix = original_prefix
        klass.reset_table_name
      when :explicit
        original = klass.instance_variable_get(:@apartment_original_table_name)
        klass.table_name = original if original
      when nil then nil # Separate-pool path — no table name qualification to undo.
      else
        warn "[Apartment] clear_config: #{klass.name} has unexpected qualification_path " \
             "#{klass.instance_variable_get(:@apartment_qualification_path).inspect}"
      end

      %i[@apartment_pinned_processed @apartment_qualification_path
         @apartment_original_table_name @apartment_original_table_name_prefix].each do |ivar|
        klass.remove_instance_variable(ivar) if klass.instance_variable_defined?(ivar)
      end
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
