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

  # Raised when a pool-lifecycle API (e.g. {Apartment.reset_tenant_pools!})
  # is invoked while Rails' transactional fixtures own one or more tenant
  # pools. Discarding a pinned pool mid-fixture-tx leaves the next example's
  # fixture-setup snapshot without those pools; the recreated pool has a
  # fresh object identity that never enrols in the rollback. Test-env-scoped
  # — production callers are unaffected.
  #
  # See docs/testing.md for the consumer-facing opt-out recipe and
  # docs/designs/fixture-pool-lifecycle.md for the failure-class design.
  class FixtureLifecycleViolation < ApartmentError
    attr_reader :pool_key

    def initialize(pool_key = nil, message: nil)
      @pool_key = pool_key
      super(message || default_message)
    end

    private

    def default_message
      pool_clause = @pool_key ? "pool '#{@pool_key}'" : 'a tenant pool'
      "reset_tenant_pools! called while #{pool_clause} is pinned by " \
        'transactional fixtures. To cycle pools mid-suite, disable ' \
        'transactional fixtures for this test (use_transactional_tests = false) ' \
        'and clean up by deletion. See docs/testing.md.'
    end
  end

  # Raised in development when a tenant has pending migrations.
  class PendingMigrationError < ApartmentError
    attr_reader :tenant

    def initialize(tenant = nil)
      @tenant = tenant
      super(
        if tenant
          "Tenant '#{tenant}' has pending migrations. Run apartment:migrate to update."
        else
          'Tenant has pending migrations. Run apartment:migrate to update.'
        end
      )
    end
  end

  # Raised by Apartment::Tenant.require_tenant! when the effective tenant is the
  # default (or unset) — routed data must not land in the default keyspace.
  class TenantRequired < ApartmentError
    attr_reader :current

    def initialize(current = nil)
      @current = current
      super(
        'Expected an explicit, non-default tenant context, but the effective ' \
        "tenant is #{current.inspect}. Wrap the work in " \
        'Apartment::Tenant.switch(name) { ... } — routed data must not use the ' \
        'default keyspace.'
      )
    end
  end

  # Raised by Apartment::Tenant.require_default_tenant! when the effective tenant
  # is a real (non-default) tenant — pinned/global work must run in the default.
  class DefaultTenantRequired < ApartmentError
    attr_reader :current, :default

    def initialize(current = nil, default = nil)
      @current = current
      @default = default
      super(
        "Expected the default tenant #{default.inspect}, but the effective " \
        "tenant is #{current.inspect}. Wrap pinned/global work in " \
        'Apartment::Tenant.with_default_tenant { ... }.'
      )
    end
  end

  # Raised by Apartment::Tenant.require_default_tenant! when no default_tenant is
  # configured: a pinned keyspace needs an explicitly named anchor, not nil.
  class DefaultTenantNotConfigured < ApartmentError
    def initialize(message = nil)
      super(
        message ||
          'require_default_tenant! needs a configured Apartment.config.default_tenant; ' \
          'none is set. A pinned keyspace requires an explicitly named default tenant.'
      )
    end
  end
end
