# frozen_string_literal: true

Apartment.configure do |config|
  config.tenants_provider = -> { %w[tenant1 tenant2 tenant3] }
  config.default_tenant = 'public'
  config.tenant_strategy = :schema
end
