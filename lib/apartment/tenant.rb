# frozen_string_literal: true

module Apartment
  module Tenant
    class << self
      # Switch to a tenant for the duration of the block.
      # Guaranteed cleanup via ensure — tenant context is always restored.
      def switch(tenant)
        raise ArgumentError, 'Apartment::Tenant.switch requires a block' unless block_given?

        previous = Current.tenant
        Current.tenant = tenant
        Current.previous_tenant = previous
        yield
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

      # Initialize: process excluded models, set up default tenant.
      def init
        adapter.process_excluded_models
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
        Apartment.adapter
      end
    end
  end
end
