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

  # Raised by the {Apartment::Patches::ConnectionHandling} prepend when
  # {Apartment::Current.tenant} is nil AND {Apartment.config.strict_tenant_lookup}
  # is enabled. Without strict mode, that call would silently return the
  # default tenant's pool — fine for explicit no-tenant code, dangerous when
  # it happens because tenant context was lost across a thread/fiber boundary
  # (e.g., a lazy association accessed outside the original Tenant.switch
  # block, or a load_async relation consumed after switch exited). Strict
  # mode turns the silent fallback into a loud failure so the leak surfaces
  # in dev/test.
  #
  # Explicit default-tenant access is still allowed: call
  # +Apartment::Tenant.switch(Apartment.config.default_tenant) { ... }+.
  #
  # See docs/designs/apartment-v4.md "Async query correctness" for the
  # failure mode this is designed to catch.
  class ImplicitDefaultTenant < ApartmentError
    def initialize(message: nil)
      super(message || default_message)
    end

    private

    def default_message
      'Apartment::Current.tenant is nil and Apartment.config.strict_tenant_lookup is enabled. ' \
        'Wrap the call in Apartment::Tenant.switch(tenant) { ... } (or call ' \
        'Apartment::Tenant.switch!(tenant) at the top of the unit of work). For explicit ' \
        'default-tenant access use Apartment::Tenant.switch(Apartment.config.default_tenant). ' \
        'Common culprit: lazy associations or load_async results accessed outside the ' \
        'original switch block. Note: Apartment::Tenant.current still falls back to ' \
        'default_tenant when Current.tenant is nil; only connection_pool raises.'
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
end
