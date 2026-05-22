# frozen_string_literal: true

require 'rack/request'
require 'apartment/tenant'

module Apartment
  module Elevators
    #   Provides a rack based tenant switching solution based on request
    #
    class Generic
      def initialize(app, processor = nil, **_options)
        @app = app
        @processor = processor || method(:parse_tenant_name)
      end

      def call(env)
        request = Rack::Request.new(env)

        begin
          database = @processor.call(request)
        rescue Apartment::TenantNotFound
          # HostHash and similar raise during resolution; route through the
          # same handler. The rescue is narrow — it does NOT wrap @app.call,
          # so a TenantNotFound raised by the application is never swallowed.
          return handle_tenant_not_found(request.host, request)
        end

        return @app.call(env) if database.nil?
        return handle_tenant_not_found(database, request) unless tenant_valid?(database)

        Apartment::Tenant.switch(database) { @app.call(env) }
      end

      def parse_tenant_name(_request)
        raise(NotImplementedError, "#{self.class}#parse_tenant_name must be implemented")
      end

      private

      # Whether `database` resolves to a real tenant. The default tenant is
      # always valid; an unconfigured Apartment skips validation entirely
      # (there is no tenant source to validate against).
      def tenant_valid?(database)
        config = Apartment.config
        return true unless config
        return true if database.to_s == config.default_tenant.to_s

        Apartment.tenant_validator.call(database)
      end

      # Route an unknown tenant through config.tenant_not_found_handler when
      # one is set; otherwise raise TenantNotFound (the railtie maps it to 404).
      def handle_tenant_not_found(tenant, request)
        handler = Apartment.config&.tenant_not_found_handler
        return handler.call(tenant, request) if handler

        raise(Apartment::TenantNotFound, "No tenant found for #{tenant.inspect}")
      end
    end
  end
end
