# frozen_string_literal: true

require 'apartment/elevators/subdomain'

module Apartment
  module Elevators
    # Tenant from the first segment of nested subdomains.
    # acme.staging.example.com -> acme
    class FirstSubdomain < Subdomain
      def parse_tenant_name(request)
        tenant = super
        return nil if tenant.nil?

        tenant.split('.').first
      end
    end
  end
end
