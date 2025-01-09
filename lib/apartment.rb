# frozen_string_literal: true

# lib/apartment.rb

require 'active_support'
require 'active_record'
require 'forwardable'
require 'monitor'

require_relative 'apartment/config'
require_relative 'apartment/tenant'
require_relative 'apartment/deprecation'
require_relative 'apartment/log_subscriber'

# Apartment module provides functionality for managing multi-tenancy in a Rails application.
# It includes methods for configuring the Apartment gem, managing tenants, and handling database connections.
module Apartment
  class << self
    extend Forwardable
    include MonitorMixin

    # @!attribute [r] config
    # @return [Apartment::Config, nil] the current configuration
    attr_reader :config

    def_delegator :config, :tenants_provider

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
        @config = Config.new

        yield(@config)

        @config.validate!
        @config.freeze!
      end
    end

    # Resets the configuration to nil in a thread-safe manner.
    # This method ensures that the reset operation is synchronized
    # using a mutex to prevent race conditions.
    def reset_config
      synchronize do
        @config = nil
      end
    end

    def tenant_names
      tenants = tenants_provider.call

      return tenants.keys if tenants.is_a?(Hash)

      tenants
    end

    def connection_config
      connection_db_config.configuration_hash
    end

    def db_config_for(tenant)
      tenants_config[tenant] || connection_config
    end

    def tenants_config
      tenants = tenants_provider.call
      return {} if tenants.blank?

      normalize_tenant_configs(tenants).with_indifferent_access
    end

    private

    def normalize_tenant_configs(names)
      names.is_a?(Hash) ? names : Array(names).index_with { connection_config }
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
  # Raised when apartment cannot find the adapter specified in <tt>config/database.yml</tt>
  class AdapterNotFound < ApartmentError; end
  # Tenant specified is unknown
  class TenantNotFound < ApartmentError; end
  # The Tenant attempting to be created already exists
  class TenantAlreadyExists < ApartmentError; end
end

require 'apartment/railtie' if defined?(Rails)
