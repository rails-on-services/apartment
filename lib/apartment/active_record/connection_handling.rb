# frozen_string_literal: true

module ActiveRecord # :nodoc:
  # This is monkeypatching Active Record to ensure that whenever a new connection is established it
  # switches to the same tenant as before the connection switching. This problem is more evident when
  # using read replica in Rails 6
  module ConnectionHandling
    if ActiveRecord.version.release <= Gem::Version.new('6.2')
      def connected_to_with_tenant(database: nil, role: nil, prevent_writes: false, &blk)
        current_tenant = Apartment::Tenant.current

        connected_to_without_tenant(database: database, role: role, prevent_writes: prevent_writes) do
          Apartment::Tenant.switch!(current_tenant)
          yield(blk)
        end
      end
    else
      def connected_to_with_tenant(role: nil, shard: nil, prevent_writes: false, &blk)
        current_tenant = Apartment::Tenant.current

        connected_to_without_tenant(role: role, shard: shard, prevent_writes: prevent_writes) do
          Apartment::Tenant.switch!(current_tenant)
          yield(blk)
        end
      end
    end

    alias connected_to_without_tenant connected_to
    alias connected_to connected_to_with_tenant
  end
end
