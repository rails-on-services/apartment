# frozen_string_literal: true

require 'active_support/callbacks'
require 'active_support/core_ext/string/inflections'
require_relative '../tenant_name_validator'

module Apartment
  module Adapters
    class AbstractAdapter
      include ActiveSupport::Callbacks

      define_callbacks :create, :switch

      # The raw database connection configuration hash (from ActiveRecord).
      # Not to be confused with Apartment.config (the Apartment::Config object).
      attr_reader :connection_config

      def initialize(connection_config)
        @connection_config = connection_config
      end

      # Template method: validates tenant name then delegates to resolve_connection_config.
      # Called by ConnectionHandling — subclasses should NOT override this.
      def validated_connection_config(tenant)
        TenantNameValidator.validate!(
          tenant,
          strategy: Apartment.config.tenant_strategy,
          adapter_name: base_config['adapter']
        )
        resolve_connection_config(tenant)
      end

      # Resolve a tenant-specific connection config hash.
      # Subclasses override to set strategy-specific keys.
      def resolve_connection_config(tenant)
        raise(NotImplementedError)
      end

      # Create a new tenant (schema or database).
      def create(tenant)
        TenantNameValidator.validate!(
          tenant,
          strategy: Apartment.config.tenant_strategy,
          adapter_name: base_config['adapter']
        )
        run_callbacks(:create) do
          create_tenant(tenant)
          import_schema(tenant) if Apartment.config.schema_load_strategy
          seed(tenant) if Apartment.config.seed_after_create
          Instrumentation.instrument(:create, tenant: tenant)
        end
      end

      # Drop a tenant.
      def drop(tenant)
        drop_tenant(tenant)
        pool_key = tenant.to_s
        pool = Apartment.pool_manager&.remove(pool_key)
        begin
          pool&.disconnect! if pool.respond_to?(:disconnect!)
        rescue StandardError => e
          warn "[Apartment] Pool disconnect failed for '#{tenant}': #{e.class}: #{e.message}"
        end
        deregister_shard_from_ar_handler(tenant)
        Instrumentation.instrument(:drop, tenant: tenant)
      end

      # Run migrations for a tenant.
      def migrate(tenant, version = nil)
        Apartment::Tenant.switch(tenant) do
          ActiveRecord::Base.connection_pool.migration_context.migrate(version)
        end
      end

      # Run seeds for a tenant.
      def seed(tenant)
        Apartment::Tenant.switch(tenant) do
          seed_file = Apartment.config.seed_data_file
          return unless seed_file

          unless File.exist?(seed_file)
            raise(Apartment::ConfigurationError,
                  "Seed file '#{seed_file}' does not exist")
          end

          load(seed_file)
        end
      end

      # Process excluded models — establish separate connections pinned to default tenant.
      def process_excluded_models
        return if Apartment.config.excluded_models.empty?

        default_config = resolve_connection_config(
          Apartment.config.default_tenant
        )

        Apartment.config.excluded_models.each do |model_name|
          klass = resolve_excluded_model(model_name)
          klass.establish_connection(default_config)

          if Apartment.config.tenant_strategy == :schema
            table = klass.table_name.split('.').last # Strip existing prefix if any
            klass.table_name = "#{default_tenant}.#{table}"
          end
        end
      end

      # Environmentify a tenant name based on config.
      # :prepend/:append require Rails to be defined (for Rails.env).
      def environmentify(tenant)
        case Apartment.config.environmentify_strategy
        when :prepend
          "#{rails_env}_#{tenant}"
        when :append
          "#{tenant}_#{rails_env}"
        when nil
          tenant.to_s
        else
          # Callable
          Apartment.config.environmentify_strategy.call(tenant)
        end
      end

      # Default tenant from config.
      def default_tenant
        Apartment.config.default_tenant
      end

      protected

      def create_tenant(tenant)
        raise(NotImplementedError)
      end

      def drop_tenant(tenant)
        raise(NotImplementedError)
      end

      private

      # Connection config with string keys (used by subclasses to build tenant configs).
      def base_config
        connection_config.transform_keys(&:to_s)
      end

      def rails_env
        unless defined?(Rails)
          raise(Apartment::ConfigurationError,
                'environmentify_strategy :prepend/:append requires Rails to be defined')
        end
        Rails.env
      end

      def resolve_excluded_model(model_name)
        model_name.constantize
      rescue NameError => e
        raise(Apartment::ConfigurationError,
              "Excluded model '#{model_name}' could not be resolved: #{e.message}")
      end

      def deregister_shard_from_ar_handler(tenant)
        Apartment.deregister_shard(tenant)
      end

      def import_schema(tenant)
        Apartment::Tenant.switch(tenant) do
          schema_file = resolve_schema_file
          case Apartment.config.schema_load_strategy
          when :schema_rb
            load(schema_file)
          when :sql
            ActiveRecord::Tasks::DatabaseTasks.load_schema(
              ActiveRecord::Base.connection_db_config, :sql, schema_file
            )
          end
        end
      rescue StandardError => e
        raise(Apartment::SchemaLoadError,
              "Failed to load schema for tenant '#{tenant}': #{e.class}: #{e.message}")
      end

      def resolve_schema_file
        custom = Apartment.config.schema_file
        return custom if custom

        if defined?(Rails) && Rails.respond_to?(:root) && Rails.root
          Rails.root.join('db/schema.rb').to_s
        else
          'db/schema.rb'
        end
      end
    end
  end
end
