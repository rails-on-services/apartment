# frozen_string_literal: true

module Apartment
  module Tenant
    class << self
      # Switch to a tenant for the duration of the block.
      # Guaranteed cleanup via ensure — tenant context is always restored.
      #
      # Note: previous_tenant reflects only the immediately preceding tenant
      # for the current switch scope. It is not stacked across nesting levels —
      # after an inner switch completes, previous_tenant resets to nil.
      def switch(tenant, &block)
        raise(ArgumentError, 'Apartment::Tenant.switch requires a block') unless block

        previous = Current.tenant
        Current.tenant = tenant
        Current.previous_tenant = previous
        if tagged_logging?
          Rails.logger.tagged(tenant, &block)
        else
          yield
        end
      ensure
        Current.tenant = previous
        Current.previous_tenant = nil
      end

      # Direct switch without block. Discouraged — prefer switch with block.
      def switch!(tenant)
        Current.previous_tenant = Current.tenant
        Current.tenant = tenant
      end

      # Current tenant name.
      def current
        Current.tenant || Apartment.config&.default_tenant
      end

      # Reset to default tenant.
      def reset
        switch!(Apartment.config&.default_tenant)
      end

      # Initialize: resolve excluded_models shim, then process pinned models.
      def init
        resolve_excluded_models_shim
        adapter.process_pinned_models
      end

      # Delegate lifecycle operations to the adapter.
      def create(tenant)
        adapter.create(tenant)
      end

      def drop(tenant)
        adapter.drop(tenant)
      end

      def migrate(tenant, version = nil)
        adapter.migrate(tenant, version)
      end

      def seed(tenant)
        adapter.seed(tenant)
      end

      # Pool stats delegated to pool_manager.
      def pool_stats
        Apartment.pool_manager&.stats || {}
      end

      private

      def adapter
        Apartment.adapter or
          raise(ConfigurationError, 'Apartment adapter not configured. Call Apartment.configure first.')
      end

      def tagged_logging?
        Apartment.config&.active_record_log &&
          defined?(Rails) && Rails.logger.respond_to?(:tagged)
      end

      # Resolve config.excluded_models strings into pinned model registrations.
      # This is the deprecated compatibility path — new code should use
      # `include Apartment::Model` + `pin_tenant` in each model.
      def resolve_excluded_models_shim
        return if Apartment.config.excluded_models.empty?

        Apartment.config.excluded_models.each do |model_name|
          klass = model_name.constantize
          next if Apartment.pinned_models.include?(klass)

          Apartment.register_pinned_model(klass)
        rescue NameError => e
          raise(Apartment::ConfigurationError,
                "Excluded model '#{model_name}' could not be resolved: #{e.message}")
        end
      end
    end
  end
end
