# frozen_string_literal: true

# lib/apartment/patches/connection_handling.rb

module Apartment
  module Patches
    module ConnectionHandling
      # Override to maintain the current tenant when switching connections
      def connected_to(role: nil, shard: nil, prevent_writes: false, &blk)
        current_tenant = Apartment::Tenant.current

        super(role: role, shard: shard, prevent_writes: prevent_writes) do
          Apartment::Tenant.switch(current_tenant, blk)
        end
      end
    end
  end
end

# Apply the patch to ActiveRecord::ConnectionHandling
ActiveSupport.on_load(:active_record) do
  ActiveRecord::ConnectionHandling.prepend(Apartment::Patches::ConnectionHandling)
end
