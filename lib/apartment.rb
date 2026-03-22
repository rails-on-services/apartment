# frozen_string_literal: true

require 'zeitwerk'
require 'active_support'
require 'active_support/current_attributes'

# Set up Zeitwerk autoloader for the Apartment namespace.
# Must happen before requiring files that define constants in the Apartment module.
loader = Zeitwerk::Loader.for_gem(warn_on_extra_files: false)
loader.inflector.inflect(
  'mysql_config' => 'MySQLConfig',
  'postgresql_config' => 'PostgreSQLConfig'
)

# errors.rb defines multiple constants (not a single Errors class),
# so it must be loaded explicitly rather than autoloaded.
loader.ignore("#{__dir__}/apartment/errors.rb")

# Ignore v3 files that haven't been replaced yet.
%w[
  railtie
  deprecation
  log_subscriber
  console
  custom_console
  migrator
  model
].each { |f| loader.ignore("#{__dir__}/apartment/#{f}.rb") }

loader.ignore("#{__dir__}/apartment/adapters")
loader.ignore("#{__dir__}/apartment/elevators")
loader.ignore("#{__dir__}/apartment/patches")
loader.ignore("#{__dir__}/apartment/tasks")
loader.ignore("#{__dir__}/apartment/active_record")

loader.setup

require_relative 'apartment/errors'

module Apartment
  class << self
    attr_reader :config, :pool_manager
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
      raise ConfigurationError, 'Apartment.configure requires a block' unless block_given?

      PoolReaper.stop
      @pool_manager&.clear
      @adapter = nil
      @config = Config.new
      yield @config
      @config.validate!
      @pool_manager = PoolManager.new
      @config
    end

    # Reset all configuration and stop background tasks.
    def clear_config
      PoolReaper.stop
      @pool_manager&.clear
      @config = nil
      @pool_manager = nil
      @adapter = nil
    end

    private

    # Factory: resolve the correct adapter class based on strategy and database adapter.
    def build_adapter
      raise ConfigurationError, 'Apartment not configured. Call Apartment.configure first.' unless @config

      strategy = config.tenant_strategy
      db_adapter = detect_database_adapter

      klass = case strategy
              when :schema
                require_relative 'apartment/adapters/postgresql_schema_adapter'
                Adapters::PostgreSQLSchemaAdapter
              when :database_name
                case db_adapter
                when /postgresql/, /postgis/
                  require_relative 'apartment/adapters/postgresql_database_adapter'
                  Adapters::PostgreSQLDatabaseAdapter
                when /mysql2/
                  require_relative 'apartment/adapters/mysql2_adapter'
                  Adapters::MySQL2Adapter
                when /trilogy/
                  require_relative 'apartment/adapters/trilogy_adapter'
                  Adapters::TrilogyAdapter
                when /sqlite/
                  require_relative 'apartment/adapters/sqlite3_adapter'
                  Adapters::SQLite3Adapter
                else
                  raise AdapterNotFound, "No adapter for database: #{db_adapter}"
                end
              else
                raise AdapterNotFound, "Strategy #{strategy} not yet implemented"
              end

      klass.new(ActiveRecord::Base.connection_db_config.configuration_hash)
    end

    def detect_database_adapter
      ActiveRecord::Base.connection_db_config.adapter
    end
  end
end
