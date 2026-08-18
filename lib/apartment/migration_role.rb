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
    # +AbstractAdapter#tenant_container_gone?+ uses: a cheap error-shape check, then an
    # authoritative probe of whether OUR role resolves. Nil means the failure is ours to
    # explain. Non-nil means the role is fine and the error belongs to something the
    # caller did inside the block, so it re-raises untouched.
    #
    # The probe is the discriminator; the class is only a pre-filter, and on the Rails
    # floor it cannot filter at all. +ActiveRecord::ConnectionNotDefined+ does not exist
    # before Rails 8.0 (absent on 7.2.3.1, present on 8.0.5 and 8.1.3), and Ruby
    # resolves a rescue clause's constants at raise time — so naming it here raised
    # NameError on 7.2 and destroyed the error it was meant to classify. 7.2 raises
    # +ConnectionNotEstablished+ for an unregistered role and 8.0+ raises the subclass,
    # so the superclass alone covers the whole matrix. Do not narrow it back.
    #
    # The cost of the wider clause is that a bare ConnectionNotEstablished from the
    # caller's own code now reaches the probe instead of passing straight through. That
    # is harmless: a registered role re-raises it exactly as before, and if our role is
    # missing then naming +ddl_role+ is correct advice whatever the immediate error was.
    #
    # Nothing arrives wrapped, which is why the clause names only ActiveRecord's error.
    # +Patches::ConnectionHandling#connection_pool+ scopes its relabelling rescue to the
    # tenant-resolution path, and a ddl_role failure is not on that path: it surfaces from
    # the default-path lookup the early guards hand to +super+, outside the scope. The
    # tenant path cannot produce one either, since it establishes a pool for the role
    # itself and so never fails on an unregistered one. The +Apartment::ApartmentError+
    # clause and the one-layer unwrap that used to sit here existed only for the
    # method-level rescue that covered those guards, and went with it.
    def wrap(&)
      role = Apartment.config.ddl_role
      return yield unless role

      ActiveRecord::Base.connected_to(role: role, &)
    rescue ActiveRecord::ConnectionNotEstablished => e
      raise if role_pool_registered?(role)

      raise(Apartment::ConfigurationError,
            "ddl_role is set to #{role.inspect} but ActiveRecord has no connection " \
            'registered for that role. Declare it with connects_to on your ' \
            "application record, or unset ddl_role. (#{e.class}: #{e.message})")
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
