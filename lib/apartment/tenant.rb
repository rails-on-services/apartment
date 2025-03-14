# frozen_string_literal: true

# lib/apartment/tenant.rb

require 'forwardable'

module Apartment
  #   The main entry point to Apartment functions
  #
  module Tenant
    class << self
      extend Forwardable

      def_delegators :config, :default_tenant, :connection_class

      def current
        # Return the current tenant
        Current.tenant
      end

      def switch(tenant = nil, &)
        previous_tenant = current || default_tenant
        Current.tenant = tenant || default_tenant
        connection_class.with_connection(&)
      ensure
        Current.tenant = previous_tenant
      end

      def switch!(tenant = nil)
        Current.tenant = tenant || default_tenant
      end

      def reset
        Current.tenant = default_tenant
      end

      private

      def config
        Apartment.config
      end
    end
  end
end
