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
    def wrap(&)
      role = Apartment.config.ddl_role
      role ? ActiveRecord::Base.connected_to(role: role, &) : yield
    end
  end
end
