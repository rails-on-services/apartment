# frozen_string_literal: true

module Apartment
  # Runs a block on the connection role configured for DDL (+config.ddl_role+).
  #
  # This lives outside Migrator because two layers need it and they sit on opposite
  # sides of the dependency arrow: Migrator drives +Tenant.switch+, and the adapters
  # it switches into issue DDL of their own at tenant-create time. Migrator keeps
  # +with_migration_role+ as its documented entry point and delegates here, so the
  # CLI and the adapters share one implementation without an adapter reaching up
  # into Migrator.
  module MigrationRole
    module_function

    # @yield block to run under +Apartment.config.ddl_role+
    # @return [Object] the block's return value
    # @raise [Apartment::ConfigurationError] when ddl_role names a role ActiveRecord
    #   cannot resolve to a connection, and the block tried to use it
    #
    # The resolution check lives here rather than at +activate!+ because +activate!+
    # runs in +after_initialize+, which railties fire after the eager-load
    # initializer: under lazy loading (development, most test setups) no model has run
    # +connects_to+ yet, so "configured but not loaded" is indistinguishable from
    # "missing" and a boot-time check would fail on every boot.
    #
    # Nothing is probed before yielding, and that is deliberate twice over.
    # +connected_to+ resolves no pool — +with_role_and_shard+ pushes onto
    # +connected_to_stack+ and yields — so an unregistered role cannot be detected
    # until the block asks for a connection. A wrap whose block never touches the
    # database therefore stays SILENT even with an unresolvable role, which is
    # correct: it did not need the role to exist. Probing up front would invent that
    # failure, and it would reintroduce the boot-order problem above for a role
    # registered lazily on a model load that has not happened yet.
    #
    # So the error is classified after the fact, in the shape
    # +AbstractAdapter#tenant_container_gone?+ uses: a cheap error-shape check
    # (ConnectionNotDefined is the subclass meaning "no pool for this role"), then an
    # authoritative probe of whether OUR role resolves. Nil means the failure is ours
    # to explain. Non-nil means the role is fine and the error belongs to something
    # the caller did inside the block, so it re-raises untouched. Bare
    # ConnectionNotEstablished is left alone entirely: it does not mean this.
    def wrap(&)
      role = Apartment.config.ddl_role
      return yield unless role

      ActiveRecord::Base.connected_to(role: role, &)
    rescue ActiveRecord::ConnectionNotDefined, Apartment::ApartmentError => e
      original = unwrap(e)
      raise unless original.is_a?(ActiveRecord::ConnectionNotDefined)
      raise if role_pool_registered?(role)

      raise(Apartment::ConfigurationError,
            "ddl_role is set to #{role.inspect} but ActiveRecord has no connection " \
            'registered for that role. Declare it with connects_to on your ' \
            "application record, or unset ddl_role. (#{original.class}: #{original.message})")
    end

    # Patches::ConnectionHandling#connection_pool has a method-level rescue that
    # relabels any StandardError as Apartment::ApartmentError, and it covers the
    # early `return super` for a nil tenant — so the role failure a create hits first
    # arrives here already wrapped, reading "Failed to resolve connection pool for
    # tenant ''". Unwrapping one layer is the same move AbstractAdapter#unwrap_db_error
    # makes for the same wrapper.
    #
    # This does not widen what gets translated. Two independent conditions still have
    # to agree: the unwrapped error must be a ConnectionNotDefined, AND our role must
    # fail to resolve. An ApartmentError carrying anything else re-raises untouched.
    def unwrap(error)
      error.is_a?(Apartment::ApartmentError) && error.cause ? error.cause : error
    end

    # Whether ActiveRecord can resolve a pool for +role+ on the current shard.
    # +retrieve_connection_pool+ returns nil for an unregistered role rather than
    # raising, which is what makes it usable as a classifier here.
    #
    # Conservative on its own failure: if the probe cannot answer, report the role as
    # registered so the original error re-raises as itself. Misreporting the other way
    # would blame ddl_role for someone else's problem.
    def role_pool_registered?(role)
      !ActiveRecord::Base.connection_handler.retrieve_connection_pool(
        ActiveRecord::Base.connection_specification_name,
        role: role,
        shard: ActiveRecord::Base.current_shard
      ).nil?
    rescue StandardError
      true
    end
  end
end
