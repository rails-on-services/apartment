# frozen_string_literal: true

require 'apartment/elevators/generic'

module Apartment
  module Elevators
    # Tenant from full hostname. Optionally strips ignored first subdomains (e.g., www).
    class Host < Generic
      def initialize(app, ignored_first_subdomains: [], **_options)
        super(app)
        @ignored_first_subdomains = Array(ignored_first_subdomains).map(&:to_s).freeze
      end

      def parse_tenant_name(request)
        return nil if request.host.blank?

        parts = request.host.split('.')
        @ignored_first_subdomains.include?(parts[0]) ? parts.drop(1).join('.') : request.host
      end
    end
  end
end
