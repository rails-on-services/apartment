# frozen_string_literal: true

require_relative 'errors'
require_relative 'configs/postgresql_config'
require_relative 'configs/mysql_config'

module Apartment
  # Configuration object for Apartment v4.
  # Created via Apartment.configure block; validated after the block yields.
  class Config
    VALID_STRATEGIES = %i[schema database_name shard database_config].freeze
    VALID_ENVIRONMENTIFY_STRATEGIES = [nil, :prepend, :append].freeze

    attr_reader :tenant_strategy, :postgres_config, :mysql_config,
                :environmentify_strategy, :excluded_models

    attr_accessor :tenants_provider, :default_tenant,
                  :tenant_pool_size, :pool_idle_timeout, :max_total_connections,
                  :seed_after_create, :seed_data_file,
                  :schema_load_strategy, :schema_file,
                  :parallel_migration_threads,
                  :elevator, :elevator_options, :elevator_insert_before,
                  :tenant_not_found_handler, :active_record_log, :sql_query_tags,
                  :shard_key_prefix,
                  :migration_role, :app_role, :schema_cache_per_tenant, :check_pending_migrations

    def initialize # rubocop:disable Metrics/AbcSize
      @tenant_strategy = nil
      @tenants_provider = nil
      @default_tenant = nil
      @excluded_models = []
      @tenant_pool_size = 5
      @pool_idle_timeout = 300
      @max_total_connections = nil
      @seed_after_create = false
      @seed_data_file = nil
      @schema_load_strategy = nil
      @schema_file = nil
      @parallel_migration_threads = 0
      @environmentify_strategy = nil
      @elevator = nil
      @elevator_options = {}
      @elevator_insert_before = nil
      @tenant_not_found_handler = nil
      @active_record_log = false
      @sql_query_tags = false
      @postgres_config = nil
      @mysql_config = nil
      @shard_key_prefix = 'apartment'
      @migration_role = nil
      @app_role = nil
      @schema_cache_per_tenant = false
      @check_pending_migrations = true
    end

    def excluded_models=(list)
      unless list.empty?
        warn '[Apartment] DEPRECATION: config.excluded_models is deprecated and will be ' \
             "removed in v5. Use `include Apartment::Model` and `pin_tenant` in each model instead.\n" \
             'For third-party gem models, use config.excluded_models as a transitional escape hatch.'
      end
      @excluded_models = list
    end

    def tenant_strategy=(strategy)
      unless VALID_STRATEGIES.include?(strategy)
        raise(ConfigurationError, "Invalid tenant_strategy: #{strategy.inspect}. " \
                                  "Must be one of: #{VALID_STRATEGIES.join(', ')}")
      end

      @tenant_strategy = strategy
    end

    def environmentify_strategy=(strategy)
      unless VALID_ENVIRONMENTIFY_STRATEGIES.include?(strategy) || strategy.respond_to?(:call)
        raise(ConfigurationError, "Invalid environmentify_strategy: #{strategy.inspect}. " \
                                  'Must be nil, :prepend, :append, or a callable')
      end

      @environmentify_strategy = strategy
    end

    # Configure PostgreSQL-specific options via block.
    def configure_postgres
      @postgres_config = Configs::PostgresqlConfig.new
      yield(@postgres_config) if block_given?
      @postgres_config
    end

    # Configure MySQL-specific options via block.
    def configure_mysql
      @mysql_config = Configs::MysqlConfig.new
      yield(@mysql_config) if block_given?
      @mysql_config
    end

    # Deep-freeze the config after validation to prevent post-boot mutation.
    # Freezes mutable collections and sub-configs, then freezes self.
    def freeze!
      @excluded_models.freeze
      @elevator_options.freeze
      @postgres_config&.freeze!
      @mysql_config&.freeze!
      # schema_file is a simple string, no deep freeze needed
      @app_role.freeze if @app_role.is_a?(String)
      freeze
    end

    # Validate configuration completeness and consistency.
    # Raises ConfigurationError on invalid state.
    def validate! # rubocop:disable Metrics/AbcSize
      raise(ConfigurationError, 'tenant_strategy is required') unless @tenant_strategy

      unless @tenants_provider.respond_to?(:call)
        raise(ConfigurationError, 'tenants_provider must be a callable (e.g., -> { Tenant.pluck(:name) })')
      end

      if @postgres_config && @mysql_config
        raise(ConfigurationError, 'Cannot configure both Postgres and MySQL at the same time')
      end

      unless @tenant_pool_size.is_a?(Integer) && @tenant_pool_size.positive?
        raise(ConfigurationError, "tenant_pool_size must be a positive integer, got: #{@tenant_pool_size.inspect}")
      end

      unless @pool_idle_timeout.is_a?(Numeric) && @pool_idle_timeout.positive?
        raise(ConfigurationError, "pool_idle_timeout must be a positive number, got: #{@pool_idle_timeout.inspect}")
      end

      if @max_total_connections && (!@max_total_connections.is_a?(Integer) || @max_total_connections < 1)
        raise(ConfigurationError,
              "max_total_connections must be a positive integer or nil, got: #{@max_total_connections.inspect}")
      end

      unless [nil, :schema_rb, :sql].include?(@schema_load_strategy)
        raise(ConfigurationError, "Invalid schema_load_strategy: #{@schema_load_strategy.inspect}. " \
                                  'Must be nil, :schema_rb, or :sql')
      end

      if @migration_role && !@migration_role.is_a?(Symbol)
        raise(ConfigurationError, "migration_role must be nil or a Symbol, got: #{@migration_role.inspect}")
      end

      if @app_role && !@app_role.is_a?(String) && !@app_role.respond_to?(:call)
        raise(ConfigurationError, "app_role must be nil, a String, or a callable, got: #{@app_role.inspect}")
      end

      unless [true, false].include?(@schema_cache_per_tenant)
        raise(ConfigurationError,
              "schema_cache_per_tenant must be true or false, got: #{@schema_cache_per_tenant.inspect}")
      end

      unless [true, false].include?(@check_pending_migrations)
        raise(ConfigurationError,
              "check_pending_migrations must be true or false, got: #{@check_pending_migrations.inspect}")
      end

      if @elevator_insert_before &&
         !@elevator_insert_before.is_a?(String) && !@elevator_insert_before.is_a?(Class)
        raise(ConfigurationError,
              "elevator_insert_before must be nil, a String, or a Class, got: #{@elevator_insert_before.inspect}")
      end

      return if @shard_key_prefix.is_a?(String) && @shard_key_prefix.match?(/\A[a-z_][a-z0-9_]*\z/)

      raise(ConfigurationError,
            'shard_key_prefix must be a lowercase string matching /[a-z_][a-z0-9_]*/, ' \
            "got: #{@shard_key_prefix.inspect}")
    end

    # Returns the current Rails environment name, falling back to env vars and a safe default.
    def rails_env_name
      (Rails.env if defined?(Rails.env)) || ENV['RAILS_ENV'] || ENV['RACK_ENV'] || 'default_env'
    end
  end
end
