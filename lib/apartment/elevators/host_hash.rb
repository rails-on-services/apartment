# frozen_string_literal: true

require 'apartment/elevators/generic'

module Apartment
  module Elevators
    # Tenant from hostname -> tenant hash mapping.
    # Raises TenantNotFound when host is not in the hash (explicit mapping; missing = config error).
    class HostHash < Generic
      def initialize(app, hash: {}, **_options)
        super(app)
        @hash = hash.freeze
      end

      def parse_tenant_name(request)
        raise(TenantNotFound, request.host) unless @hash.key?(request.host)

        @hash[request.host]
      end
    end
  end
end
