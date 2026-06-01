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
        rescue Apartment::TenantNotFound => e
          # HostHash and similar raise during resolution; route through the
          # same handler. The rescue is narrow — it does NOT wrap @app.call,
          # so a TenantNotFound raised by the application is never swallowed.
          # Prefer the exception's own tenant; fall back to the host.
          return handle_tenant_not_found(e.tenant || request.host, request)
        end

        return @app.call(env) if database.nil?
        return handle_tenant_not_found(database, request) unless tenant_valid?(database)

        switch_with_failsafe(database, request) { @app.call(env) }
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

      # Switch into +tenant+ and run the app. In v4 the switch is SQL-free, so a
      # tenant dropped by another process is not detected until the app's first
      # query fails inside this block. When that error is one the adapter
      # recognizes as "the tenant container is gone" (a stale positive in the
      # validator), evict the name from this process and route through the
      # not-found path — turning a lingering-drop 500 into a 404. Any other
      # error, including an app-raised one, re-raises untouched. Adapters that
      # declare no failsafe error classes skip the rescue entirely.
      def switch_with_failsafe(tenant, request, &)
        adapter = resolve_adapter
        classes = adapter&.failsafe_error_classes
        return Apartment::Tenant.switch(tenant, &) if classes.blank?

        begin
          Apartment::Tenant.switch(tenant, &)
        rescue *classes => e
          raise unless adapter.tenant_container_gone?(e, tenant)

          # Eviction is best-effort: config.tenant_validator may be `false` (a
          # bare always-valid lambda) or a custom callable with no #evict. The
          # 404 for a confirmed-gone tenant stands regardless; only the built-in
          # validator's positive set is memoized.
          validator = Apartment.tenant_validator
          validator.evict(tenant) if validator.respond_to?(:evict)
          handle_tenant_not_found(tenant, request)
        end
      end

      # The memoized adapter, or nil when it cannot be resolved (Apartment
      # unconfigured, or no database connection yet). A nil adapter disables the
      # fail-safe — the switch runs plain, preserving today's behavior — so the
      # elevator never fails trying to *set up* the fail-safe. The rescue is
      # scoped to the setup-time failures (unconfigured, or no connection yet) —
      # a genuine bug in adapter resolution is left to surface, not swallowed.
      def resolve_adapter
        Apartment.adapter
      rescue Apartment::ApartmentError, ActiveRecord::ConnectionNotEstablished
        nil
      end

      # Route an unknown tenant through config.tenant_not_found_handler when
      # one is set; otherwise raise TenantNotFound (the railtie maps it to 404).
      def handle_tenant_not_found(tenant, request)
        handler = Apartment.config&.tenant_not_found_handler
        return handler.call(tenant, request) if handler

        # TenantNotFound.new's argument is the tenant name — it builds its own
        # message. Pass the bare name so #tenant and #message stay correct.
        raise(Apartment::TenantNotFound, tenant)
      end
    end
  end
end
