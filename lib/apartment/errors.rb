# frozen_string_literal: true

module Apartment
  # Base error for all Apartment exceptions.
  class ApartmentError < StandardError; end

  # Raised when a tenant cannot be found.
  class TenantNotFound < ApartmentError
    attr_reader :tenant

    def initialize(tenant = nil)
      @tenant = tenant
      super(tenant ? "Tenant '#{tenant}' not found" : 'Tenant not found')
    end
  end

  # Raised when attempting to create a tenant that already exists.
  class TenantExists < ApartmentError
    attr_reader :tenant

    def initialize(tenant = nil)
      @tenant = tenant
      super(tenant ? "Tenant '#{tenant}' already exists" : 'Tenant already exists')
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

  # Raised in development when a tenant has pending migrations.
  class PendingMigrationError < ApartmentError
    attr_reader :tenant

    def initialize(tenant = nil)
      @tenant = tenant
      super(
        tenant ? "Tenant '#{tenant}' has pending migrations. Run apartment:migrate to update."
               : 'Tenant has pending migrations. Run apartment:migrate to update.'
      )
    end
  end
end
