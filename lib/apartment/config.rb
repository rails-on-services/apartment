# frozen_string_literal: true

# lib/apartment/config.rb

module Apartment
  # Configuration options for Apartment.
  class Config
    extend Forwardable

    # Specifies the strategy by which tenants are separated.
    # @!attribute [r] tenant_strategy
    attr_reader :tenant_strategy

    # Specifies a callable object responsible for providing a list or hashes of tenants.
    # Tenants can be represented as either strings or hashes.
    # Return a hash only if tenants are split between databases or shards
    # in which case the hash should include the tenant name and the
    # corresponding database name, database config, or shard name.
    #
    # For shards, the hash should include both the tenant name and the shard name:
    #   [{ tenant: 'tenant1', shard: 'shard1' }, { tenant: 'tenant2', shard: 'shard2' }]
    # Note: Every shard must be defined in the database configuration and tenant_strategy must be set to :shard
    #
    # The same can be done for database names
    #  [{ tenant: 'tenant1', database: 'database1' }, { tenant: 'tenant2', database: 'database2' }]
    # Note: tenant_strategy must be set to :database_name. The same database config will be used for all tenants.
    #
    # Lastly, you can return a hash with the tenant name and the database configuration:
    # [{ tenant: 'tenant1', database_config: { ... } }, { tenant: 'tenant2', database_config: { ... } }]
    # Note: tenant_strategy must be set to :database_config. These configs don't need to be in the database.yml file.
    #
    # @!attribute [rw] tenants_provider
    # @return [Proc] A callable object that returns an array of tenant names.
    attr_accessor :tenants_provider

    # Sets the default tenant. In Postgres, this is typically the public schema.
    # This doesn't necessarily have to be a tenant listed by `tenants_provider`.
    # @!attribute [rw] default_tenant
    # @return [String, nil] the name of the default tenant schema
    attr_accessor :default_tenant

    # Adds current database and schemas to ActiveRecord logs.
    # @!attribute [rw] active_record_log
    # @return [Boolean] true if logs should include database and schemas
    attr_accessor :active_record_log

    # Specifies how to namespace the tenant with the current environment.
    # This is only used when the tenant strategy is not set to :database_config
    # @!attribute [r] environmentify
    # @return [Symbol, Proc, nil] :prepend, :append, or a callable object for transforming tenant names
    # @raise [ArgumentError] if an invalid value is set
    attr_reader :environmentify_strategy

    # Specifies the base connection class to use for database connections.
    # @!attribute [r] connection_class
    # @return [Class] the connection class, defaults to ActiveRecord::Base
    attr_reader :connection_class

    # Specifies the Postgres-specific configuration options, if any
    # @!attribute [r] postgres_config
    # @return [Apartment::Configs::PostgresConfig, nil]
    attr_reader :postgres_config

    # Specifies the MySQL-specific configuration options, if any
    # @!attribute [r] mysql_config
    # @return [Apartment::Configs::MysqlConfig, nil]
    attr_reader :mysql_config

    def_delegators :connection_class, :connection_db_config

    def initialize
      @tenants_provider = nil
      @default_tenant = nil
      @active_record_log = true
      @environmentify_strategy = nil
      @database_schema_file = default_database_schema_file
      @connection_class = ActiveRecord::Base
      @postgres_config = nil
      @mysql_config = nil
    end

    # Validates the configuration.
    # @raise [ConfigurationError] if the configuration is invalid
    def validate!
      unless tenants_provider.is_a?(Proc)
        raise(ConfigurationError,
              'tenants_provider must be a callable (e.g., -> { Tenant.pluck(:name) })')
      end

      if postgres_config && mysql_config
        raise(ConfigurationError, 'Cannot configure both Postgres and MySQL at the same time')
      end

      postgres_config&.validate!
      mysql_config&.validate!
    end

    def apply!
      postgres_config&.apply!
      mysql_config&.apply!
    end

    TENANT_STRATEGIES = %i[schema shard database_name database_config].freeze
    private_constant :TENANT_STRATEGIES

    def tenant_strategy=(value)
      validate_strategy!(value, TENANT_STRATEGIES, 'tenant_strategy')
      @tenant_strategy = value
    end

    ENVIRONMENTIFY_STRATEGIES = [nil, :prepend, :append].freeze
    private_constant :ENVIRONMENTIFY_STRATEGIES

    # Sets the strategy for transforming tenant names with the current environment.
    # @!attribute [w] environmentify_strategy
    # @param [Symbol, Proc, nil] value: nil, :prepend, :append, or a callable object
    # @return [Symbol, Proc, nil] nil, :prepend, :append, or a callable object
    def environmentify_strategy=(value)
      validate_strategy!(value, ENVIRONMENTIFY_STRATEGIES, 'environmentify_strategy') unless value.respond_to?(:call)
      @environmentify_strategy = value
    end

    # Sets the connection class to use for database connections.
    # @!attribute [w] connection_class
    # @param [Class] klass the connection class
    # @return [Class] the connection class
    def connection_class=(klass)
      # Ensure the connection class is either ActiveRecord::Base or a subclass
      unless klass <= ActiveRecord::Base
        raise(ConfigurationError, 'Connection class must be ActiveRecord::Base or a subclass of it')
      end

      @connection_class = klass

      @connection_class.default_connection_handler = Apartment::ConnectionAdapters::ConnectionHandler.new

      connection_class
    end

    def configure_postgres(&)
      @postgres_config = Configs::PostgreSQLConfig.new
      yield(@postgres_config)
    end

    def configure_mysql(&)
      @mysql_config = Configs::MySQLConfig.new
      yield(@mysql_config)
    end

    private

    # Validates the strategy for a given key.
    # @param [Object] value
    # @param [Array<Object>] valid_strategies
    # @param [String] key_name
    # @raise [ArgumentError] if the value is not valid
    def validate_strategy!(value, valid_strategies, key_name)
      return if valid_strategies.include?(value)

      raise(ArgumentError, "Option #{value} not valid for `#{key_name}`. Use one of #{valid_strategies.join(', ')}")
    end

    # Returns the default database schema file.
    # If Rails is defined, the default path is `db/schema.rb`.
    # @return [String, nil] the path to the database schema file
    def default_database_schema_file
      defined?(Rails) && Rails.root ? Rails.root.join('db/schema.rb') : nil
    end
  end
end
