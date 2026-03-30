# frozen_string_literal: true

require 'apartment/elevators/generic'
require 'public_suffix'

module Apartment
  module Elevators
    # Tenant from subdomain. Uses PublicSuffix for international TLD handling.
    class Subdomain < Generic
      def initialize(app, excluded_subdomains: [], **_options)
        super(app)
        @excluded_subdomains = Array(excluded_subdomains).map(&:to_s).freeze
      end

      def parse_tenant_name(request)
        request_subdomain = subdomain(request.host)

        return nil if request_subdomain.blank?
        return nil if @excluded_subdomains.include?(request_subdomain)

        request_subdomain
      end

      protected

      def subdomain(host)
        subdomains(host).first
      end

      def subdomains(host)
        host_valid?(host) ? parse_host(host) : []
      end

      def host_valid?(host)
        !ip_host?(host) && domain_valid?(host)
      end

      def ip_host?(host)
        !/^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$/.match(host).nil?
      end

      def domain_valid?(host)
        PublicSuffix.valid?(host, ignore_private: true)
      end

      def parse_host(host)
        (PublicSuffix.parse(host, ignore_private: true).trd || '').split('.')
      end
    end
  end
end
