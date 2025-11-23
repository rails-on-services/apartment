# frozen_string_literal: true

require 'apartment/elevators/generic'
require 'public_suffix'

module Apartment
  module Elevators
    #   Provides a rack based tenant switching solution based on subdomains
    #   Assumes that tenant name should match subdomain
    #
    class Subdomain < Generic
      def self.excluded_subdomains
        @excluded_subdomains ||= []
      end

      # rubocop:disable Style/TrivialAccessors
      def self.excluded_subdomains=(arg)
        @excluded_subdomains = arg
      end
      # rubocop:enable Style/TrivialAccessors

      def parse_tenant_name(request)
        request_subdomain = subdomain(request.host)

        # Excluded subdomains (www, api, admin) return nil → uses default tenant.
        # Returning nil instead of default_tenant name allows Apartment to decide
        # the fallback behavior.
        tenant = if self.class.excluded_subdomains.include?(request_subdomain)
                   nil
                 else
                   request_subdomain
                 end

        tenant.presence
      end

      protected

      # Subdomain extraction using PublicSuffix to handle international TLDs correctly.
      # Examples: api.example.com → "api", www.example.co.uk → "www"

      def subdomain(host)
        subdomains(host).first  # Only first subdomain matters for tenant resolution
      end

      def subdomains(host)
        host_valid?(host) ? parse_host(host) : []
      end

      def host_valid?(host)
        !ip_host?(host) && domain_valid?(host)
      end

      # Reject IP addresses (127.0.0.1, 192.168.1.1) - no subdomain concept
      def ip_host?(host)
        !/^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$/.match(host).nil?
      end

      def domain_valid?(host)
        PublicSuffix.valid?(host, ignore_private: true)
      end

      # PublicSuffix.parse handles TLDs correctly: example.co.uk has TLD "co.uk"
      # .trd (third-level domain) returns subdomain parts, excluding TLD
      def parse_host(host)
        (PublicSuffix.parse(host, ignore_private: true).trd || '').split('.')
      end
    end
  end
end
