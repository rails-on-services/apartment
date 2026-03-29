# frozen_string_literal: true

require 'active_record'

module Apartment
  module Patches
    # Prepended on ActiveRecord::Base (singleton class) to intercept
    # connection_pool lookups. When Apartment::Current.tenant is set,
    # returns a tenant-specific pool keyed by AR shard, with config
    # resolved by the adapter.
    module ConnectionHandling
      def connection_pool # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        tenant = Apartment::Current.tenant
        cfg = Apartment.config

        # No tenant, no config, or default tenant — normal Rails behavior.
        return super if tenant.nil? || cfg.nil?
        return super if tenant.to_s == cfg.default_tenant.to_s
        return super unless Apartment.pool_manager

        pool_key = tenant.to_s

        # Leverage AR's ConnectionHandler for pool lifecycle (checkout, checkin,
        # reaping). We register tenant configs as named shards — AR handles the rest.
        Apartment.pool_manager.fetch_or_create(pool_key) do
          config = Apartment.adapter.validated_connection_config(tenant)
          prefix = cfg.shard_key_prefix
          shard_key = :"#{prefix}_#{tenant}"

          db_config = ActiveRecord::DatabaseConfigurations::HashConfig.new(
            cfg.rails_env_name,
            "#{prefix}_#{tenant}",
            config
          )

          ActiveRecord::Base.connection_handler.establish_connection(
            db_config,
            owner_name: ActiveRecord::Base,
            role: ActiveRecord::Base.current_role,
            shard: shard_key
          )
        end
      rescue Apartment::ApartmentError
        raise
      rescue StandardError => e
        raise(Apartment::ApartmentError,
              "Failed to resolve connection pool for tenant '#{tenant}': #{e.class}: #{e.message}")
      end
    end
  end
end
