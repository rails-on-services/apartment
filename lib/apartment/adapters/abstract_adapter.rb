# frozen_string_literal: true

require 'active_support/callbacks'
require 'active_support/core_ext/string/inflections'

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

      # Resolve a tenant-specific connection config hash.
      # Subclasses override to set strategy-specific keys.
      def resolve_connection_config(tenant)
        raise(NotImplementedError)
      end

      # Create a new tenant (schema or database).
      def create(tenant)
        run_callbacks(:create) do
          create_tenant(tenant)
          Instrumentation.instrument(:create, tenant: tenant)
        end
      end

      # Drop a tenant.
      def drop(tenant)
        drop_tenant(tenant)
        # Remove cached pool (key is tenant.to_s, must match pool key used in Phase 2.3 ConnectionHandling)
        pool_key = tenant.to_s
        pool = Apartment.pool_manager&.remove(pool_key)
        pool&.disconnect! if pool.respond_to?(:disconnect!)
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
          load(seed_file) if seed_file && File.exist?(seed_file)
        end
      end

      # Process excluded models — establish separate connections pinned to default tenant.
      def process_excluded_models
        default_config = resolve_connection_config(
          Apartment.config.default_tenant
        )

        Apartment.config.excluded_models.each do |model_name|
          klass = model_name.constantize
          klass.establish_connection(default_config)
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
    end
  end
end
