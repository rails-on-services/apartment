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
end
