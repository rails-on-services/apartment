# frozen_string_literal: true

require 'active_record'

module Apartment
  module Patches
    # Prepended on ActiveRecord::Base (singleton class) to intercept
    # connection_pool lookups. When Apartment::Current.tenant is set,
    # returns a tenant-specific pool keyed by "tenant:role", with config
    # resolved by the adapter using the current role's base config.
    module ConnectionHandling
      def connection_pool # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        tenant = Apartment::Current.tenant
        cfg = Apartment.config

        return super if tenant.nil? || cfg.nil?
        return super if tenant.to_s == cfg.default_tenant.to_s
        return super unless Apartment.pool_manager

        role = ActiveRecord::Base.current_role
        pool_key = "#{tenant}:#{role}"

        Apartment.pool_manager.fetch_or_create(pool_key) do
          default_pool = super
          base = default_pool.db_config.configuration_hash.stringify_keys

          config = Apartment.adapter.validated_connection_config(tenant, base_config_override: base)
          prefix = cfg.shard_key_prefix
          shard_key = :"#{prefix}_#{pool_key}"

          db_config = ActiveRecord::DatabaseConfigurations::HashConfig.new(
            cfg.rails_env_name,
            "#{prefix}_#{pool_key}",
            config
          )

          pool = ActiveRecord::Base.connection_handler.establish_connection(
            db_config,
            owner_name: ActiveRecord::Base,
            role: role,
            shard: shard_key
          )

          if check_pending_migrations?(pool)
            raise(Apartment::PendingMigrationError.new(tenant))
          end

          if cfg.schema_cache_per_tenant
            load_tenant_schema_cache(tenant, pool)
          end

          pool
        end
      rescue Apartment::ApartmentError
        raise
      rescue StandardError => e
        raise(Apartment::ApartmentError,
              "Failed to resolve connection pool for tenant '#{tenant}': #{e.class}: #{e.message}")
      end

      private

      def check_pending_migrations?(pool)
        return false unless Apartment.config.check_pending_migrations
        return false unless defined?(Rails) && Rails.env.local?
        return false if Apartment::Current.migrating

        pool.migration_context.needs_migration?
      end

      def load_tenant_schema_cache(tenant, pool)
        require_relative '../schema_cache'
        cache_path = Apartment::SchemaCache.cache_path_for(tenant)
        return unless File.exist?(cache_path)

        pool.schema_cache.load!(cache_path)
      end
    end
  end
end
