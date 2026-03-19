# frozen_string_literal: true

module Apartment
  # Base error for all Apartment exceptions.
  class ApartmentError < StandardError; end

  # Raised when a tenant cannot be found.
  class TenantNotFound < ApartmentError
    def initialize(tenant = nil)
      msg = tenant ? "Tenant '#{tenant}' not found" : 'Tenant not found'
      super(msg)
    end
  end

  # Raised when attempting to create a tenant that already exists.
  class TenantExists < ApartmentError
    def initialize(tenant = nil)
      msg = tenant ? "Tenant '#{tenant}' already exists" : 'Tenant already exists'
      super(msg)
    end
  end

  # Raised when the requested database adapter is not found.
  class AdapterNotFound < ApartmentError; end

  # Raised on invalid configuration.
  class ConfigurationError < ApartmentError; end

  # Raised when the tenant connection pool is exhausted.
  class PoolExhausted < ApartmentError; end

  # Raised when schema loading fails during tenant creation.
  class SchemaLoadError < ApartmentError; end
end
