# frozen_string_literal: true

# lib/apartment/patches/connection_handling.rb

module Apartment
  module Patches
    # Patches/overrides ActiveRecord::ConnectionHandling methods to handle multi-tenancy
    module ConnectionHandling
      # Establishes the connection to the database.
      # Override
      def establish_connection(config_or_env = nil)
        config_or_env ||= ActiveRecord::ConnectionHandling::DEFAULT_ENV.call.to_sym
        db_config = resolve_config_for_connection(config_or_env)
        if connection_handler.is_a?(Apartment::ConnectionAdapters::ConnectionHandler)
          connection_handler.establish_connection(db_config, owner_name: self, role: current_role, shard: current_shard,
                                                             tenant: target_tenant)
        else
          connection_handler.establish_connection(db_config, owner_name: self, role: current_role, shard: current_shard)
        end
      end

      # Checkouts a connection from the pool, yield it and then check it back in.
      # Override
      if ActiveRecord.version < Gem::Version.new('7.2.0')
        def with_connection(&)
          connection_pool.with_connection(&)
        end
      else
        def with_connection(prevent_permanent_checkout: false, &)
          connection_pool.with_connection(prevent_permanent_checkout:, &)
        end
      end

      # Returns the connection specification name from the current class or its parent.
      # Override
      def connection_specification_name
        base_connection_name = @connection_specification_name || (
          self == ActiveRecord::Base ? ActiveRecord::Base.name : superclass.connection_specification_name)

        tenant = target_tenant

        current_scoped_tenant = base_connection_name.match(/\[([a-zA-Z0-9_-]+)\]/).to_a.last

        # If both the current scoped tenant and the target tenant are the same (or nil),
        # return the base connection name
        return base_connection_name if current_scoped_tenant == tenant

        # If only the tenant is nil, return the base connection name without a tenant
        # because we want a tenant-less connection
        return base_connection_name.gsub(/\[#{current_scoped_tenant}\]/i, '') if tenant.nil?

        # If there is no current scoped tenant, return the base connection name with the new tenant
        # because we want a tenant-scoped connection
        return "#{base_connection_name}[#{tenant}]" if current_scoped_tenant.nil?

        # If the connection name includes a different tenant, return
        # the base connection name with the new tenant, replacing the old tenant
        base_connection_name.gsub(/\[#{current_scoped_tenant}\]/i, "[#{tenant}]")
      end

      # Override
      def connection_pool
        connection_handler.retrieve_connection_pool(
          connection_specification_name,
          role: current_role,
          shard: current_shard,
          strict: true,
          tenant: target_tenant
        )
      end

      # Override
      def retrieve_connection
        connection_handler.retrieve_connection(
          connection_specification_name,
          role: current_role,
          shard: current_shard,
          tenant: target_tenant
        )
      end

      # Override
      def connected?
        connection_handler.connected?(
          connection_specification_name,
          role: current_role,
          shard: current_shard,
          tenant: target_tenant
        )
      end

      # Override
      def remove_connection
        name = @connection_specification_name if defined?(@connection_specification_name)

        # if removing a connection that has a pool, we reset the
        # connection_specification_name so it will use the parent pool.
        if connection_handler.retrieve_connection_pool(name, role: current_role, shard: current_shard,
                                                             tenant: target_tenant)
          self.connection_specification_name = nil
        end

        connection_handler.remove_connection_pool(name, role: current_role, shard: current_shard, tenant: target_tenant)
      end

      private

      def target_tenant
        try(:pinned_tenant) || Apartment::Tenant.current
      end

      # Override
      def resolve_config_for_connection(config_or_env)
        raise('Anonymous class is not allowed.') unless name

        self.connection_specification_name = (primary_class? ? ActiveRecord::Base.name : name).gsub(/\[.*\]/, '')

        # Punt resolving the configuration to the ConnectionHandler
        # Not sure why Rails doesn't do this by default
        config_or_env
      end

      # Override
      def with_role_and_shard(role, shard, prevent_writes, tenant = nil)
        prevent_writes = true if role == ActiveRecord.reading_role

        append_to_connected_to_stack(role: role, shard: shard, prevent_writes: prevent_writes, klasses: [self],
                                     tenant: tenant || target_tenant)
        return_value = yield
        return_value.load if return_value.is_a?(ActiveRecord::Relation)
        return_value
      ensure
        connected_to_stack.pop
      end

      def append_to_connected_to_stack(entry)
        if shard_swapping_prohibited? && entry[:shard].present?
          raise(ArgumentError, 'cannot swap `shard` while shard swapping is prohibited.')
        end

        entry[:tenant] = target_tenant if entry[:tenant].nil?

        connected_to_stack << entry
      end
    end
  end
end

# Apply the patch to ActiveRecord::ConnectionHandling
ActiveSupport.on_load(:active_record) do
  ActiveRecord::ConnectionHandling.prepend(Apartment::Patches::ConnectionHandling)
end
