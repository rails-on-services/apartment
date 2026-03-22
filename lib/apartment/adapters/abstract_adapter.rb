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
        raise NotImplementedError
      end

      # Create a new tenant (schema or database).
      def create(tenant)
        run_callbacks :create do
          create_tenant(tenant)
          Instrumentation.instrument(:create, tenant: tenant)
        end
      end

      # Drop a tenant.
      def drop(tenant)
        drop_tenant(tenant)
        # Remove cached pool (key format must match ConnectionHandling#connection_pool)
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
      def environmentify(tenant)
        case Apartment.config.environmentify_strategy
        when :prepend
          "#{Rails.env}_#{tenant}"
        when :append
          "#{tenant}_#{Rails.env}"
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
        raise NotImplementedError
      end

      def drop_tenant(tenant)
        raise NotImplementedError
      end
    end
  end
end
