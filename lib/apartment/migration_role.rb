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
    #   cannot resolve to a connection
    #
    # The resolution check lives here rather than at +activate!+ because +activate!+
    # runs in +after_initialize+, which railties fire after the eager-load
    # initializer: under lazy loading (development, most test setups) no model has run
    # +connects_to+ yet, so "configured but not loaded" is indistinguishable from
    # "missing" and a boot-time check would fail on every boot.
    #
    # +entered+ separates the two ways this can raise. +connected_to+ calls the block,
    # so a ConnectionNotEstablished from a query INSIDE it arrives at the same rescue;
    # translating that would report a caller's own failure as "your ddl_role is
    # misconfigured". Once the block has started, the role resolved, and the error
    # belongs to the caller.
    def wrap
      role = Apartment.config.ddl_role
      return yield unless role

      entered = false
      ActiveRecord::Base.connected_to(role: role) do
        entered = true
        yield
      end
    rescue ActiveRecord::ConnectionNotDefined, ActiveRecord::ConnectionNotEstablished => e
      raise if entered

      raise(Apartment::ConfigurationError,
            "ddl_role is set to #{role.inspect} but ActiveRecord has no connection " \
            'registered for that role. Declare it with connects_to on your ' \
            "application record, or unset ddl_role. (#{e.class}: #{e.message})")
    end
  end
end
