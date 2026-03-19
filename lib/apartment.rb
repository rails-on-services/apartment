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
  tenant
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
    end
  end
end
