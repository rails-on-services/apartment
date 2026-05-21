# frozen_string_literal: true

Apartment.configure do |config|
  config.tenant_strategy = :schema
  config.tenants_provider = -> { Company.pluck(:database) }
  config.default_tenant = 'public'
  config.elevator = :subdomain
  config.schema_load_strategy = nil # dummy app manages its own schema
end
