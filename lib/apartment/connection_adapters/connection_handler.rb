# frozen_string_literal: true

require 'delegate'

module Apartment
  module ConnectionAdapters
    # Extends and replaces the ActiveRecord::ConnectionAdapters::ConnectionHandler class to
    # provide multi-tenancy support. A connection pool will be created for each owner
    # (typically AR model), role, shard, and tenant combination.
    class ConnectionHandler < ActiveRecord::ConnectionAdapters::ConnectionHandler # rubocop:disable Metrics/ClassLength
      # A wrapper class for AR model class, contextualizing the class with a specified tenant.
      # This class allows the ConnectionHandler to uniquely identify connection pools based on the
      # combination of the model class and a tenant.
      #
      # Example:
      #   base_class = MyModel
      #   tenant = "tenant_1"
      #   wrapper = TenantConnectionDescriptor.new(base_class, tenant)
      #   wrapper.name # => "MyModel[tenant_1]"
      #   wrapper.primary_class? # => false (primary_class? is delegated to the base class, MyModel)
      #
      # This wrapper ensures that:
      # 1. Connection pools are correctly isolated per tenant.
      # 2. Rails models can interact with tenant-specific connections without modifying core behaviors.
      class TenantConnectionDescriptor < SimpleDelegator
        attr_reader :tenant, :name

        # Initializes a new TenantConnectionDescriptor instance.
        #
        # @param base_class [Class] The base class to wrap (typically an ActiveRecord model).
        # @param tenant [String, nil] The name of the tenant. If the base class has a pinned tenant,
        #  that tenant will be used instead. If pinned tenant is not present and tenant is nil,
        #  the base class name will be used without any tenant context.
        def initialize(base_class, tenant = nil)
          super(base_class)
          @tenant = base_class.try(:pinned_tenant) || tenant
          @name = if @tenant.present? && !base_class.name.end_with?("[#{@tenant}]")
                    "#{base_class.name}[#{@tenant}]"
                  else
                    base_class.name
                  end
        end
      end

      # Override
      # rubocop:disable Metrics/ParameterLists, Metrics/AbcSize, Metrics/MethodLength
      def establish_connection(config, owner_name: Base, role: Base.current_role, shard: Base.current_shard,
                               clobber: false, tenant: nil)
        owner_name = determine_owner_name(owner_name, config,
                                          tenant || Apartment::Tenant.current)
        tenant = owner_name.tenant

        pool_config = resolve_pool_config(config, owner_name, role, shard, tenant)

        # This db_config is now tenant-specific
        db_config = pool_config.db_config

        pool_manager = set_pool_manager(pool_config.connection_class, tenant:)

        # If there is an existing pool with the same values as the pool_config
        # don't remove the connection. Connections should only be removed if we are
        # establishing a connection on a class that is already connected to a different
        # configuration.
        existing_pool_config = pool_manager.get_pool_config(role, shard)

        if !clobber && existing_pool_config && existing_pool_config.db_config == db_config
          # Update the pool_config's connection class if it differs. This is used
          # for ensuring that ActiveRecord::Base and the primary_abstract_class use
          # the same pool. Without this granular swapping will not work correctly.
          if owner_name.primary_class? && (existing_pool_config.connection_class != owner_name)
            existing_pool_config.connection_class = owner_name
          end

          existing_pool_config.pool
        else
          disconnect_pool_from_pool_manager(pool_manager, role, shard)
          pool_manager.set_pool_config(role, shard, pool_config)

          payload = {
            connection_name: pool_config.connection_class.name,
            role: role,
            shard: shard,
            tenant: tenant,
            config: db_config.configuration_hash,
          }

          ActiveSupport::Notifications.instrumenter.instrument('!connection.active_record',
                                                               payload) do
            pool_config.pool
          end
        end
      end
      # rubocop:enable Metrics/ParameterLists, Metrics/AbcSize, Metrics/MethodLength

      # Locate the connection of the nearest super class. This can be an
      # active or defined connection: if it is the latter, it will be
      # opened and set as the active connection for the class it was defined
      # for (not necessarily the current class).
      #
      # Override
      def retrieve_connection(connection_name, role: ActiveRecord::Base.current_role,
                              shard: ActiveRecord::Base.current_shard, tenant: nil)
        pool = retrieve_connection_pool(connection_name, role: role, shard: shard, strict: true, tenant: tenant)

        if ActiveRecord.version < Gem::Version.new('7.2.0')
          pool.connection
        else
          pool.lease_connection
        end
      end

      # Returns true if a connection that's accessible to this class has
      # already been opened.
      #
      # Override
      def connected?(connection_name, role: ActiveRecord::Base.current_role, shard: ActiveRecord::Base.current_shard,
                     tenant: nil)
        pool = retrieve_connection_pool(connection_name, role: role, shard: shard, tenant: tenant)
        pool&.connected?
      end

      # Override
      def remove_connection_pool(connection_name, role: ActiveRecord::Base.current_role,
                                 shard: ActiveRecord::Base.current_shard, tenant: nil)
        return unless (pool_manager = get_pool_manager(connection_name, tenant: tenant))

        disconnect_pool_from_pool_manager(pool_manager, role, shard)
      end

      # Retrieving the connection pool happens a lot, so we cache it in @connection_name_to_pool_manager.
      # This makes retrieving the connection pool O(1) once the process is warm.
      # When a connection is established or removed, we invalidate the cache.
      #
      # Override
      # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      def retrieve_connection_pool(connection_name, role: ActiveRecord::Base.current_role,
                                   shard: ActiveRecord::Base.current_shard, strict: false, tenant: nil)
        pool_manager = get_pool_manager(connection_name, tenant: tenant)
        # if there is not a pool manager or pool config, try to establish a connection
        pool = pool_manager&.get_pool_config(role, shard)&.pool || establish_connection(
          Rails.env.to_sym,
          owner_name: connection_name,
          role: role,
          shard: shard,
          tenant: tenant
        )

        if strict && !pool
          selector = [
            ("'#{shard}' shard" unless shard == ActiveRecord::Base.default_shard),
            ("'#{role}' role" unless role == ActiveRecord::Base.default_role),
            ("'#{tenant}' tenant" unless tenant),
          ].compact.join(' and ')

          selector = [
            (connection_name unless connection_name == 'ActiveRecord::Base'),
            selector.presence,
          ].compact.join(' with ')

          selector = " for #{selector}" if selector.present?

          message = "No database connection defined#{selector}."

          unless ActiveRecord.version >= Gem::Version.new('8.0.0')
            raise(ActiveRecord::ConnectionNotEstablished,
                  message)
          end

          raise(ActiveRecord::ConnectionNotDefined.new(
                  message,
                  connection_name: connection_name, shard: shard, role: role,
                  tenant: tenant
                ))

        end

        pool
      end
      # rubocop:enable Metrics/AbcSize, Metrics/MethodLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

      private

      # Returns the pool manager for a connection name / identifier.
      def get_pool_manager(connection_name, tenant: nil)
        if tenant.present? && connection_name.present? && !connection_name.end_with?("[#{tenant}]")
          connection_name = "#{connection_name}[#{tenant}]"
        end
        connection_name_to_pool_manager[connection_name]
      end

      # Get the existing pool manager or initialize and assign a new one.
      def set_pool_manager(connection_class, tenant: nil)
        connection_name = connection_class.name
        if tenant.present? && connection_name.present? && !connection_name.end_with?("[#{tenant}]")
          connection_name = "#{connection_name}[#{tenant}]"
        end

        existing_pool_manager = connection_name_to_pool_manager[connection_name]
        return existing_pool_manager if existing_pool_manager

        connection_name_to_pool_manager[connection_name] = ConnectionAdapters::PoolManager.new
      end

      # Returns an instance of PoolConfig for a given adapter.
      # Accepts a hash one layer deep that contains all connection information.
      #
      # == Example
      #
      #   config = { "production" => { "host" => "localhost", "database" => "foo", "adapter" => "sqlite3" } }
      #   pool_config = Base.configurations.resolve(:production)
      #   pool_config.db_config.configuration_hash
      #   # => { host: "localhost", database: "foo", adapter: "sqlite3" }
      #
      # @param config [Hash] The configuration hash containing connection information.
      # @param connection_name [TenantConnectionDescriptor] The tenant-specific connection name.
      # @param role [Symbol] The role for the connection.
      # @param shard [Symbol] The shard for the connection.
      # @return [ConnectionAdapters::PoolConfig] The resolved pool configuration.
      #
      # Override
      def resolve_pool_config(config, connection_name, role, shard, tenant = nil)
        db_config_details = Apartment::DatabaseConfigurations.resolve_for_tenant(
          config,
          role:,
          shard:,
          tenant: tenant || connection_name.tenant
        )

        db_config = db_config_details[:db_config]
        role = db_config_details[:role]
        shard = db_config_details[:shard]

        raise(AdapterNotSpecified, 'database configuration does not specify adapter') unless db_config.adapter

        ConnectionAdapters::PoolConfig.new(connection_name, db_config, role, shard)
      end

      def determine_owner_name(owner_name, config, tenant = nil)
        TenantConnectionDescriptor.new(super(owner_name, config), tenant)
      end
    end
  end
end
