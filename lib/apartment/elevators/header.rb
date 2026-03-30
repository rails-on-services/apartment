# frozen_string_literal: true

require 'apartment/elevators/generic'

module Apartment
  module Elevators
    # Tenant from HTTP header. For infrastructure that injects tenant identity at the edge
    # (CloudFront, Nginx, API gateway).
    #
    # The trusted: flag is consumed by the Railtie for a boot-time warning;
    # the elevator itself behaves identically regardless of trust level.
    class Header < Generic
      attr_reader :raw_header

      def initialize(app, header: 'X-Tenant-Id', **_options)
        super(app)
        @header_name = "HTTP_#{header.upcase.tr('-', '_')}"
        @raw_header = header.freeze
      end

      def parse_tenant_name(request)
        request.get_header(@header_name).presence
      end
    end
  end
end
