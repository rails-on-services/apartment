# frozen_string_literal: true

Apartment.configure do |config|
  config.tenant_strategy = :schema
  config.tenants_provider = -> { Company.pluck(:database) }
  config.default_tenant = 'public'
  config.excluded_models = ['Company']
  config.elevator = :subdomain
  config.schema_load_strategy = nil # dummy app manages its own schema
  config.configure_postgres do |pg|
    pg.persistent_schemas = %w[public]
  end
end
