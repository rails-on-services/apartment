# frozen_string_literal: true

# lib/apartment/configs/postgres_config.rb

module Apartment
  # Postgres specific configuration options for Apartment.
  module Configs
    class PostgresConfig
      # Use schemas for each tenant instead of discrete databases.
      # @!attribute [rw] use_schemas
      # @return [Boolean] true if schemas should be used for tenants, defaults to false
      attr_accessor :use_schemas

      # Prevents `create_schema` statements from appearing in the Rails-generated schema.rb
      # @!attribute [rw] skip_create_schema
      # @return [Boolean] true if `create_schema` statements should be omitted, defaults to true
      attr_accessor :skip_create_schema

      # Use raw SQL from pg_dump for creating new schemas.
      # @!attribute [rw] use_sql
      # @return [Boolean] true if raw SQL should be used, defaults to false
      attr_accessor :use_sql

      # Check each tenant for which database to use.
      # @!attribute [rw] with_multi_server_setup
      # @return [Boolean] true if multi-server setup is enabled, defaults to false
      attr_accessor :with_multi_server_setup

      # Specifies models that should always be accessed from the default tenant.
      # @!attribute [rw] excluded_models
      # @return [Array<String>] a list of models excluded from tenant scoping, defaults to an empty array
      attr_accessor :excluded_models

      # Skip tables listed in `excluded_models` during `patch_search_path` replacements
      # and excluded them from the clone target to prevent SQL issues with pg_dump.
      # @!attribute [rw] exclude_tables_from_clone
      # @return [Boolean] true if tables in `excluded_models` should be excluded, defaults to false
      attr_accessor :exclude_tables_from_clone

      # Specifies schemas that will always remain in the search_path when switching or resetting tenants.
      # @!attribute [rw] persistent_schemas
      # @return [Array<String>] a list of schemas to keep in the search_path, defaults to an empty array
      attr_accessor :persistent_schemas

      # Specifies items in the schema dump that should retain their default namespace
      # (e.g., `public`) instead of being replaced with the tenant namespace.
      # Useful for references like default UUID generation.
      # @!attribute [rw] excluded_names
      # @return [Array<String>] a list of items to retain their default namespace, defaults to an empty array
      attr_accessor :excluded_names

      def initialize
        @use_schemas = false
        @skip_create_schema = true
        @use_sql = false
        @with_multi_server_setup = false
        @excluded_models = []
        @exclude_tables_from_clone = false
        @persistent_schemas = []
        @excluded_names = []
      end

      # Validates the configuration.
      # @raise [ConfigurationError] if the configuration is invalid
      def validate!
        # Do nothing for now
      end
    end
  end
end
