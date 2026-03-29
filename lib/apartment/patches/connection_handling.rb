# frozen_string_literal: true

require 'active_record'

module Apartment
  module Patches
    # Prepended on ActiveRecord::Base (singleton class) to intercept
    # connection_pool lookups. When Apartment::Current.tenant is set,
    # returns a tenant-specific pool with immutable, tenant-scoped config.
    module ConnectionHandling
      def connection_pool # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        tenant = Apartment::Current.tenant
        cfg = Apartment.config
        default = cfg&.default_tenant

        return super if tenant.nil? || tenant.to_s == default.to_s
        return super unless Apartment.pool_manager

        pool_key = tenant.to_s

        Apartment.pool_manager.fetch_or_create(pool_key) do
          config = Apartment.adapter.resolve_connection_config(tenant)
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
      end
    end
  end
end
