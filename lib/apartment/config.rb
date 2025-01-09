# frozen_string_literal: true

# lib/apartment/config.rb

module Apartment
  # Configuration options for Apartment.
  class Config
    # Specifies a callable object responsible for providing the list of tenants.
    #
    # Note: This method is called frequently, so ensure it is performant.
    # For complex queries, consider caching the results to avoid repeated
    # calculations or database hits.
    #
    # @!attribute [rw] tenants_provider
    # @return [Proc] a callable object that returns an array of tenant names
    attr_accessor :tenants_provider

    # Sets the default tenant. In Postgres, this is typically the public schema.
    # This doesn't necessarily have to be a tenant listed by `tenants_provider`.
    # @!attribute [rw] default_tenant
    # @return [String, nil] the name of the default tenant schema
    attr_accessor :default_tenant

    # Ensures the tenant exists before switching.
    # @!attribute [rw] tenant_presence_check
    # @return [Boolean] true if Apartment should verify tenant existence
    attr_accessor :tenant_presence_check

    # Adds current database and schemas to ActiveRecord logs.
    # @!attribute [rw] active_record_log
    # @return [Boolean] true if logs should include database and schemas
    attr_accessor :active_record_log

    # Seeds the database after creating a new tenant.
    # @!attribute [rw] seed_after_create
    # @return [Boolean] true if seeding should occur after tenant creation
    attr_accessor :seed_after_create

    # Specifies how to namespace the tenant with the current environment.
    # @!attribute [r] environmentify
    # @return [Symbol, Proc, nil] :prepend, :append, or a callable object for transforming tenant names
    # @raise [ArgumentError] if an invalid value is set
    attr_reader :environmentify

    # Specifies the file to use for the database schema.
    # @!attribute [rw] database_schema_file
    # @return [String, nil] the path to the database schema file, defaults to db/schema.rb in Rails
    attr_accessor :database_schema_file

    # Specifies the file to use for seeding data.
    # @!attribute [rw] seed_data_file
    # @return [String, nil] the path to the seed data file, defaults to db/seeds.rb in Rails
    attr_accessor :seed_data_file

    # Specifies the connection class to use for database connections.
    # @!attribute [rw] connection_class
    # @return [Class] the connection class, defaults to ActiveRecord::Base
    attr_accessor :connection_class

    # Should Apartment should run db:migrate for each tenant
    # @!attribute [rw] db_migrate_tenants
    # @return [Boolean] true if migrations should be applied to tenants, defaults to true
    attr_accessor :db_migrate_tenants

    # Specifies how to handle a missing tenant during db:migrate
    # @!attribute [r] db_migrate_tenant_missing_strategy
    # @return [:rescue_exception, :raise_exception, :create_tenant] the strategy to use
    #   for missing tenants, defaults to :rescue_exception
    attr_reader :db_migrate_tenant_missing_strategy

    # Specifies the number of threads to use for parallel tenant migrations.
    # Behavior for 0 is defined by the parallel gem
    # @!attribute [rw] parallel_migration_threads
    # @return [Integer, nil] the number of threads, or nil for default behavior;
    attr_accessor :parallel_migration_threads

    # Specifies the Postgres-specific configuration options, if any
    # @!attribute [r] postgres_config
    # @return [Apartment::Configs::PostgresConfig, nil]
    attr_reader :postgres_config

    # Specifies the MySQL-specific configuration options, if any
    # @!attribute [r] mysql_config
    # @return [Apartment::Configs::MysqlConfig, nil]
    attr_reader :mysql_config

    def initialize
      @tenants_provider = nil
      @default_tenant = nil
      @tenant_presence_check = true
      @active_record_log = true
      @seed_after_create = false
      @environmentify = nil
      @database_schema_file = default_database_schema_file
      @seed_data_file = default_seed_data_file
      @connection_class = ActiveRecord::Base
      @db_migrate_tenants = true
      @db_migrate_tenant_missing_strategy = :rescue_exception
      @parallel_migration_threads = nil
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

    ENVIRONMENTIFY_STRATEGIES = [nil, :prepend, :append].freeze
    private_constant :ENVIRONMENTIFY_STRATEGIES

    # Sets the strategy for transforming tenant names with the current environment.
    # @!attribute [w] environmentify
    # @param [Symbol, Proc, nil] value: nil, :prepend, :append, or a callable object
    # @return [Symbol, Proc, nil] nil, :prepend, :append, or a callable object
    def environmentify=(value)
      validate_strategy!(value, ENVIRONMENTIFY_STRATEGIES, 'environmentify') unless value.respond_to?(:call)
      @environmentify = value
    end

    MISSING_TENANT_STRATEGIES = %i[rescue_exception raise_exception create_tenant].freeze
    private_constant :MISSING_TENANT_STRATEGIES

    # Sets the strategy for handling a missing tenant during db:migrate.
    # @!attribute [w] db_migrate_tenant_missing_strategy
    # @param [:rescue_exception, :raise_exception, :create_tenant] value the strategy to use
    # @return [:rescue_exception, :raise_exception, :create_tenant] the strategy to use
    def db_migrate_tenant_missing_strategy=(value)
      validate_strategy!(value, MISSING_TENANT_STRATEGIES, 'db_migrate_tenant_missing_strategy')
      @db_migrate_tenant_missing_strategy = value
    end

    def configure_postgres(&)
      require_relative('configs/postgres_config')
      @postgres_config = Configs::PostgresConfig.new
      yield(@postgres_config)
    end

    def configure_mysql(&)
      require_relative('configs/mysql_config')
      @mysql_config = Configs::MysqlConfig.new
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

    # Returns the default seed data file.
    # If Rails is defined, the default path is `db/seeds.rb`.
    # @return [String, nil] the path to the seed data file
    def default_seed_data_file
      defined?(Rails) && Rails.root ? Rails.root.join('db/seeds.rb') : nil
    end
  end
end
