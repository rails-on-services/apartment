# frozen_string_literal: true

require_relative 'errors'
require_relative 'configs/postgresql_config'
require_relative 'configs/mysql_config'

module Apartment
  # Immutable-ish configuration object for Apartment v4.
  # Created via Apartment.configure block; validated on freeze.
  class Config
    VALID_STRATEGIES = %i[schema database_name shard database_config].freeze
    VALID_PARALLEL_STRATEGIES = %i[auto threads processes].freeze
    VALID_ENVIRONMENTIFY_STRATEGIES = [nil, :prepend, :append].freeze

    attr_reader :tenant_strategy
    attr_accessor :tenants_provider
    attr_accessor :default_tenant, :excluded_models, :persistent_schemas
    attr_accessor :tenant_pool_size, :pool_idle_timeout, :max_total_connections
    attr_accessor :seed_after_create, :seed_data_file
    attr_accessor :parallel_migration_threads, :parallel_strategy
    attr_accessor :environmentify_strategy
    attr_accessor :elevator, :elevator_options
    attr_accessor :tenant_not_found_handler
    attr_accessor :active_record_log
    attr_reader :postgres_config, :mysql_config

    def initialize
      @tenant_strategy = nil
      @tenants_provider = nil
      @default_tenant = nil
      @excluded_models = []
      @persistent_schemas = []
      @tenant_pool_size = 5
      @pool_idle_timeout = 300
      @max_total_connections = nil
      @seed_after_create = false
      @seed_data_file = nil
      @parallel_migration_threads = 0
      @parallel_strategy = :auto
      @environmentify_strategy = nil
      @elevator = nil
      @elevator_options = {}
      @tenant_not_found_handler = nil
      @active_record_log = false
      @postgres_config = nil
      @mysql_config = nil
    end

    def tenant_strategy=(strategy)
      unless VALID_STRATEGIES.include?(strategy)
        raise ConfigurationError, "Invalid tenant_strategy: #{strategy.inspect}. " \
                                  "Must be one of: #{VALID_STRATEGIES.join(', ')}"
      end

      @tenant_strategy = strategy
    end

    def parallel_strategy=(strategy)
      unless VALID_PARALLEL_STRATEGIES.include?(strategy)
        raise ConfigurationError, "Invalid parallel_strategy: #{strategy.inspect}. " \
                                  "Must be one of: #{VALID_PARALLEL_STRATEGIES.join(', ')}"
      end

      @parallel_strategy = strategy
    end

    def environmentify_strategy=(strategy)
      unless VALID_ENVIRONMENTIFY_STRATEGIES.include?(strategy) || strategy.respond_to?(:call)
        raise ConfigurationError, "Invalid environmentify_strategy: #{strategy.inspect}. " \
                                  'Must be nil, :prepend, :append, or a callable'
      end

      @environmentify_strategy = strategy
    end

    # Configure PostgreSQL-specific options via block.
    def configure_postgres
      @postgres_config = Configs::PostgreSQLConfig.new
      yield @postgres_config if block_given?
      @postgres_config
    end

    # Configure MySQL-specific options via block.
    def configure_mysql
      @mysql_config = Configs::MySQLConfig.new
      yield @mysql_config if block_given?
      @mysql_config
    end

    # Validate configuration completeness and consistency.
    # Raises ConfigurationError on invalid state.
    def validate!
      raise ConfigurationError, 'tenant_strategy is required' unless @tenant_strategy

      unless @tenants_provider.respond_to?(:call)
        raise ConfigurationError, 'tenants_provider must be a callable (e.g., -> { Tenant.pluck(:name) })'
      end

      if @postgres_config && @mysql_config
        raise ConfigurationError, 'Cannot configure both Postgres and MySQL at the same time'
      end
    end
  end
end
