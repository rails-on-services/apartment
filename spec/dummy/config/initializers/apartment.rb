# frozen_string_literal: true

Apartment.configure do |config|
  config.tenant_strategy = :schema
  # Static tenant list for the dummy app: the request-lifecycle spec creates
  # exactly these tenants, and the elevator validates resolved subdomains
  # against this list before switching.
  config.tenants_provider = -> { %w[public acme widgets] }
  config.default_tenant = 'public'
  config.elevator = :subdomain
  config.schema_load_strategy = nil # dummy app manages its own schema
  # Integration specs that use this initializer (request_lifecycle_spec,
  # live_streaming_spec) create tenant tables directly via create_table, not
  # via migrations. The check_pending_migrations? gate would otherwise raise
  # Apartment::PendingMigrationError on every Tenant.switch when another
  # integration spec leaves the per-tenant schema_migrations empty on
  # Rails 8.0 PG (see issue #423). Disabling the check is appropriate for the
  # dummy app — no production behavior is affected.
  config.check_pending_migrations = false
end
