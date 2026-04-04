# frozen_string_literal: true

require 'zeitwerk'
require 'active_support'
require 'active_support/current_attributes'

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

loader.setup

require_relative 'apartment/errors'

module Apartment
  class << self
    attr_reader :config, :pool_manager, :pool_reaper
    attr_writer :adapter

    # Lazy-loading adapter. Built on first access via build_adapter.
    # Can be set manually (e.g., in tests) via Apartment.adapter=.
    def adapter
      @adapter ||= build_adapter
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
      @config = nil
      @pool_manager = nil
      @pool_reaper = nil
    end

    # Activate the ConnectionHandling patch on ActiveRecord::Base.
    # Idempotent — prepend on an already-prepended module is a no-op.
    def activate!
      require_relative('apartment/patches/connection_handling')
      ActiveRecord::Base.singleton_class.prepend(Patches::ConnectionHandling)
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
