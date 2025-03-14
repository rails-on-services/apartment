# frozen_string_literal: true

# lib/apartment.rb

require 'active_support'
require 'active_record'
require 'forwardable'
require 'monitor'

require 'zeitwerk'
loader = Zeitwerk::Loader.for_gem(warn_on_extra_files: false)
loader.inflector.inflect(
  'mysql_config' => 'MySQLConfig',
  'postgresql_config' => 'PostgreSQLConfig',
  'mysql' => 'MySQL',
  'postgresql' => 'PostgreSQL',
  'sqlite' => 'SQLite'
)
loader.collapse("#{__dir__}/apartment/concerns")
loader.setup

# Apartment module provides functionality for managing multi-tenancy in a Rails application.
# It includes methods for configuring the Apartment gem, managing tenants, and handling database connections.
module Apartment
  extend MonitorMixin
  class << self
    extend Forwardable

    # @!attribute [r] config
    # @return [Apartment::Config, nil] the current configuration
    attr_reader :config

    def_delegators :config, :default_tenant, :connection_class

    # Configures the Apartment gem.
    #
    # This method allows you to set up the configuration for the Apartment gem.
    # It ensures that the configuration can only be set once and is thread-safe.
    # Once the configuration is set, it is validated and frozen to prevent further modifications.
    #
    # @yield [Config] The configuration object to be set up.
    # @raise [ConfigurationError] If the configuration has already been initialized and frozen.
    #
    # @example
    #   Apartment.configure do |config|
    #     config.some_setting = 'value'
    #   end
    def configure(&)
      raise(ConfigurationError, 'Apartment configuration cannot be changed after initialization') if config&.frozen?

      synchronize do
        Logger.debug('Initializing config')
        @config = Config.new

        yield(@config)

        @config.validate!
        # @config.freeze!
        Logger.debug('Config initialized and frozen')
      end
    end

    # Resets the configuration to nil in a thread-safe manner.
    # This method ensures that the reset operation is synchronized
    # using a mutex to prevent race conditions.
    def reset_config
      synchronize do
        remove_instance_variable(:@config) if defined?(@config)
        @tenant_configs = nil
        Logger.debug('Config reset')
      end
    end

    def tenant_configs
      return @tenant_configs if @tenant_configs # rubocop:disable ThreadSafety/ClassInstanceVariable

      synchronize do
        Logger.debug('Initializing tenant configs')
        @tenant_configs = config.tenants_provider.call
        @tenant_configs.freeze
        Logger.debug('Tenant configs initialized and frozen')
      end
    end
  end

  # Exceptions
  class ApartmentError < StandardError; end
  # Raised if Apartment is not properly configured
  class ConfigurationError < ApartmentError; end
  # Apartment namespaced version of ArgumentError
  class ArgumentError < ::ArgumentError; end
  # Raised when a required file cannot be found
  class FileNotFound < ApartmentError; end
  # Tenant specified is unknown
  class TenantNotFound < ApartmentError; end
  # The Tenant attempting to be created already exists
  class TenantAlreadyExists < ApartmentError; end
end

if defined?(Rails)
  require 'apartment/railtie'
  require 'apartment/patches/connection_handling'
end
