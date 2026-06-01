# frozen_string_literal: true

module Apartment
  module Tenant # rubocop:disable Metrics/ModuleLength
    class << self # rubocop:disable Metrics/ClassLength
      # Switch to a tenant for the duration of the block.
      # Guaranteed cleanup via ensure — tenant context is always restored.
      #
      # Note: previous_tenant reflects only the immediately preceding tenant
      # for the current switch scope. It is not stacked across nesting levels —
      # after an inner switch completes, previous_tenant resets to nil.
      def switch(tenant, &block)
        raise(ArgumentError, 'Apartment::Tenant.switch requires a block') unless block

        guard_default_tenant_switch!(tenant)

        previous = Current.tenant
        Current.tenant = tenant
        Current.previous_tenant = previous
        if tagged_logging?
          Rails.logger.tagged("tenant=#{tenant}", &block)
        else
          yield
        end
      ensure
        Current.tenant = previous
        Current.previous_tenant = nil
      end

      # Direct switch without block. Discouraged — prefer switch with block.
      def switch!(tenant)
        Current.previous_tenant = Current.tenant
        Current.tenant = tenant
      end

      # Current tenant name.
      def current
        Current.tenant || Apartment.config&.default_tenant
      end

      # Reset to default tenant.
      def reset
        switch!(Apartment.config&.default_tenant)
      end

      # Predicate: was a tenant explicitly entered? (Explicitness axis.)
      # Reads Current.tenant directly (not Tenant.current) so it does NOT
      # consider the default_tenant fallback. Use this when "did this code
      # explicitly enter a tenant?" matters more than "what tenant is
      # effectively active?" — typically test setup and assertion code.
      #
      # Note: after Tenant.reset, tenant_switched? returns true. reset enters the
      # default tenant via switch!, which is an explicit entry.
      def tenant_switched?
        !Current.tenant.nil?
      end

      # Raise if no tenant has been explicitly entered. (Explicitness axis.)
      # Test-time discipline for suites that want to fail loudly when ambient
      # writes would land in the default tenant. No-op when a tenant is active.
      def assert_tenant_switched!(message: nil)
        return if tenant_switched?

        raise(Apartment::ApartmentError,
              message ||
              'Expected an explicit tenant context, but Apartment::Current.tenant is nil. ' \
              'Wrap the call in Apartment::Tenant.switch(tenant) { ... } or call ' \
              'Apartment::Tenant.switch!(tenant).')
      end

      # Predicate: is the effective tenant a real, NON-default tenant?
      # (Identity axis — reads Tenant.current, default fallback included.)
      def in_tenant?
        c = current
        !c.nil? && c.to_s != Apartment.config&.default_tenant.to_s
      end

      # Predicate: is the effective tenant the default tenant?
      # (Identity axis.) False when no default_tenant is configured.
      def in_default_tenant?
        default = Apartment.config&.default_tenant
        !default.nil? && current.to_s == default.to_s
      end

      # Guard: raise unless the effective tenant is a real, non-default tenant.
      # Returns the normalized tenant name on success (a documented convenience;
      # the cache recipe uses cache_namespace, not this return, for the proc).
      def require_tenant!
        return current.to_s if in_tenant?

        raise(Apartment::TenantRequired, current)
      end

      # Guard: raise unless the effective tenant is the default tenant. Returns
      # the normalized default name on success. Raises DefaultTenantNotConfigured
      # when no default_tenant is configured (a nil keyspace is a silent leak).
      def require_default_tenant!
        default = Apartment.config&.default_tenant
        raise(Apartment::DefaultTenantNotConfigured) if default.nil?
        return default.to_s if current.to_s == default.to_s

        raise(Apartment::DefaultTenantRequired.new(current, default))
      end

      # Routed cache namespace helper: asserts a real, non-default tenant and
      # returns its normalized name. Intended as a fail-closed cache namespace
      # proc — `namespace: -> { Apartment::Tenant.cache_namespace }`.
      def cache_namespace
        require_tenant!
      end

      # Establish the default/pinned tenant context for the block, then restore
      # the prior Current.tenant (including nil) on exit or raise. Enters default
      # via direct Current assignment — the guard-exempt path that reset/switch!
      # use — so it is NOT blocked by default_tenant_switch_allowed = false. Use
      # for pinned/global work (e.g. writing app-wide cache keys).
      #
      # Raises DefaultTenantNotConfigured when no default_tenant is configured,
      # mirroring require_default_tenant! — entering a nil keyspace for pinned
      # work is a silent leak, not a valid global context.
      def with_default_tenant
        raise(ArgumentError, 'Apartment::Tenant.with_default_tenant requires a block') unless block_given?

        default = Apartment.config&.default_tenant
        raise(Apartment::DefaultTenantNotConfigured) if default.nil?

        previous = Current.tenant
        begin
          Current.tenant = default
          Current.previous_tenant = previous
          yield
        ensure
          Current.tenant = previous
          Current.previous_tenant = nil
        end
      end

      # Initialize: resolve excluded_models shim, then process pinned models.
      def init
        resolve_excluded_models_shim
        adapter.process_pinned_models
      end

      # Delegate lifecycle operations to the adapter.
      def create(tenant)
        adapter.create(tenant)
      end

      def drop(tenant)
        adapter.drop(tenant)
      end

      def migrate(tenant, version = nil)
        adapter.migrate(tenant, version)
      end

      def seed(tenant)
        adapter.seed(tenant)
      end

      # Iterate over all tenants, switching into each for the duration of the block.
      # Accepts an optional tenant list; defaults to tenants_provider.
      # Fail-fast: raises immediately if a block raises for any tenant;
      # tenants after the failing one are not visited.
      def each(tenants = nil)
        raise(ArgumentError, 'Apartment::Tenant.each requires a block') unless block_given?

        tenants ||= Apartment.tenant_names
        tenants.each { |tenant| switch(tenant) { yield(tenant) } }
      end

      # Block-scoped override of the tenant resolver. For the duration of the
      # block, every "what tenants do we have?" call site (Apartment.tenant_names,
      # Tenant.each, Migrator, SchemaCache, CLI commands) reads from +source+
      # instead of config.tenants_provider.
      #
      # The override is in-process, fiber-safe, and block-local. It does NOT
      # automatically propagate to ActiveJob workers, child threads, or other
      # processes — pass tenant names as job arguments if cross-process scoping
      # is required.
      #
      # Accepted shapes for +source+:
      #
      #   * A callable (responds to +:call+) — re-evaluated on every
      #     +Apartment.tenant_names+ access inside the block. Use a frozen Array
      #     instead if you need a stable snapshot.
      #   * A String or Symbol — coerced to a single-element Array of strings.
      #   * An Array of String/Symbol — coerced to an Array of strings.
      #
      # Anything else (+nil+, Hash, arbitrary object) raises ArgumentError. Empty
      # arrays are honored — Tenant.each yields zero times. Nesting fully
      # replaces the outer override; the previous value is restored on block
      # exit (including via raise).
      #
      # The accepted shapes are intentionally broader than +config.tenants_provider+,
      # which requires a callable. The block override targets test-suite ergonomics
      # where a literal list is the natural call shape; the configured provider stays
      # callable-only because production tenant lists are nearly always backed by a
      # query that should resolve at access time. The contract that internal callers
      # see — what +Apartment.tenant_names+ returns — is identical: an object that
      # responds to +:each+, validated at resolution.
      #
      #   Apartment::Tenant.with_tenants_provider(['acme', 'widgets']) do
      #     Apartment::Tenant.each { |t| ... }       # yields acme, widgets only
      #   end
      #
      #   Apartment::Tenant.with_tenants_provider(-> { Account.recent.pluck(:id) }) do
      #     Apartment::Tenant.each { |t| ... }
      #   end
      def with_tenants_provider(source)
        raise(ArgumentError, 'Apartment::Tenant.with_tenants_provider requires a block') unless block_given?

        override = coerce_tenant_override(source)

        previous = Current.tenant_override
        Current.tenant_override = override
        begin
          yield
        ensure
          Current.tenant_override = previous
        end
      end

      # Convenience splat over with_tenants_provider for the common case of an
      # enumerated list of names.
      #
      #   Apartment::Tenant.with_tenants('acme', 'widgets') do
      #     Apartment::Tenant.each { |t| ... }
      #   end
      def with_tenants(*names, &)
        with_tenants_provider(names, &)
      end

      # Pool stats delegated to pool_manager.
      def pool_stats
        Apartment.pool_manager&.stats || {}
      end

      private

      # Raise when default_tenant_switch_allowed is false and the caller is
      # block-switching into the default tenant. switch! and reset are exempt:
      # neither enters this guard, so they remain the legitimate paths into
      # the default tenant under strict mode.
      def guard_default_tenant_switch!(tenant)
        cfg = Apartment.config
        return if cfg.nil? || cfg.default_tenant_switch_allowed
        return if cfg.default_tenant.nil?
        return unless tenant.to_s == cfg.default_tenant.to_s

        raise(Apartment::ApartmentError,
              "switch(#{cfg.default_tenant.inspect}) is disabled by " \
              'default_tenant_switch_allowed = false. Inside a block scope, call ' \
              'Apartment::Tenant.reset to re-enter the default tenant. For non-block ' \
              'scopes (suite bootstrap, before(:context)), use Apartment::Tenant.switch!(name).')
      end

      # Validate and coerce a +with_tenants_provider+ source argument.
      # Callables pass through. String, Symbol, and Arrays of String/Symbol
      # become a frozen Array<String>. Everything else raises ArgumentError —
      # silently coercing nil/Hash/random objects produces tenant names like
      # "" or "[:k, v]" that fail far from the call site.
      def coerce_tenant_override(source)
        return source if source.respond_to?(:call)

        names = wrap_tenant_names(source)
        validate_tenant_name_array!(names)
        names.map(&:to_s).freeze
      end

      def wrap_tenant_names(source)
        case source
        when String, Symbol then [source]
        when Array          then source
        else
          raise(ArgumentError,
                'Apartment::Tenant.with_tenants_provider expects a callable, ' \
                "String, Symbol, or Array of String/Symbol; got #{source.class}")
        end
      end

      def validate_tenant_name_array!(names)
        return if names.all? { |n| n.is_a?(String) || n.is_a?(Symbol) }

        raise(ArgumentError,
              'Apartment::Tenant.with_tenants_provider Array entries must be ' \
              'String or Symbol')
      end

      def adapter
        Apartment.adapter or
          raise(ConfigurationError, 'Apartment adapter not configured. Call Apartment.configure first.')
      end

      def tagged_logging?
        Apartment.config&.active_record_log &&
          defined?(Rails) && Rails.logger.respond_to?(:tagged)
      end

      # Resolve config.excluded_models strings into pinned model registrations.
      # This is the deprecated compatibility path — new code should use
      # `include Apartment::Model` + `pin_tenant` in each model.
      def resolve_excluded_models_shim
        return if Apartment.config.excluded_models.empty?

        Apartment.config.excluded_models.each do |model_name|
          klass = model_name.constantize
          next if Apartment.pinned_models.include?(klass)

          Apartment.register_pinned_model(klass)
        rescue NameError => e
          raise(Apartment::ConfigurationError,
                "Excluded model '#{model_name}' could not be resolved: #{e.message}")
        end
      end
    end
  end
end
