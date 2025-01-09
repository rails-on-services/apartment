# frozen_string_literal: true

# lib/apartment/tenant.rb

require 'forwardable'
require_relative 'current'
require_relative 'adapters'

module Apartment
  #   The main entry point to Apartment functions
  #
  module Tenant
    class << self
      extend Forwardable

      def_delegators :adapter, :create, :drop, :switch, :switch!, :current, :each,
                     :reset, :init, :set_callback, :seed, :default_tenant, :environmentify

      #   Fetch the proper multi-tenant adapter based on Rails config
      #
      #   @return {subclass of Apartment::AbstractAdapter}
      #
      def adapter
        Apartment::Current.adapter ||= begin
          adapter_method = "#{config[:adapter]}_adapter"

          unless Apartment::Adapters.respond_to?(adapter_method)
            raise(AdapterNotFound, "database configuration specifies nonexistent #{config[:adapter]} adapter")
          end

          send(adapter_method, config)
        end
      end

      #   Reset config and adapter so they are regenerated
      #
      def reload!
        Apartment::Current.reset_all
      end

      def config
        Apartment.connection_config
      end
    end
  end
end
