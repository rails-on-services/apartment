# frozen_string_literal: true

require 'active_record'
require_relative '../tenant_name_validator'

module Apartment
  module Patches
    # Prepended on ActiveRecord::Base (singleton class) to intercept
    # connection_pool lookups. When Apartment::Current.tenant is set,
    # returns a tenant-specific pool keyed by "tenant:role", with config
    # resolved by the adapter using the current role's base config.
    module ConnectionHandling
      def connection_pool # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
        tenant = Apartment::Current.tenant
        cfg = Apartment.config

        return super if tenant.nil? || cfg.nil?
        return super if tenant.to_s == cfg.default_tenant.to_s
        return super unless Apartment.pool_manager

        # Skip tenant override for pinned models only when the adapter requires
        # a separate pool (shared_pinned_connection? is false). When shared
        # connections are supported (PG schema, MySQL), pinned models fall
        # through to the tenant pool lookup, preserving transactional integrity.
        # When adapter is nil (unconfigured), falls back to separate pool (safe default).
        adapter = Apartment.adapter
        if self != ActiveRecord::Base && Apartment.pinned_model?(self) &&
           (adapter.nil? || !adapter.shared_pinned_connection?)
          return super
        end

        # Reject pool-key-unsafe tenant names BEFORE building pool_key or entering
        # fetch_or_create. In the capped path, fetch_or_admit runs admit! (which
        # may LRU-evict an idle pool) before the adapter validates inside the
        # block, so a colon / whitespace / NUL in the raw tenant — which would
        # also corrupt the "#{tenant}:#{role}" key and PoolManager's prefix
        # matching — must be caught here. ConfigurationError is an ApartmentError,
        # so the rescue below re-raises it cleanly.
        Apartment::TenantNameValidator.validate_common!(tenant.to_s)

        role = ActiveRecord::Base.current_role
        pool_key = "#{tenant}:#{role}"

        Apartment.pool_manager.fetch_or_create(pool_key) do
          # RE-ENTRANCY: when max_total_connections is set, this block runs under
          # PoolManager's @create_mutex (non-reentrant). Nothing here may resolve
          # ActiveRecord::Base.connection_pool for the current tenant — it would
          # re-enter fetch_or_create and self-deadlock. `super` resolves the
          # default pool (bypasses the patch), and check_pending_migrations? /
          # schema-cache load operate on the explicit `pool`, so all are safe.
          # Keep it that way if you add work to this block.
          # Resolve base config from the current role's default pool when available.
          # Falls back to nil (adapter uses its own base_config) when the default pool
          # is not accessible — e.g., in worker threads during parallel migration where
          # the ConnectionHandler may not have the pool registered for this context.
          # NOTE: `super` must be called here (not in a helper) because it refers to
          # the original connection_pool method on AR::Base, which only resolves from
          # the prepended method scope.
          base = begin
            default_pool = super
            default_pool.db_config.configuration_hash.stringify_keys
          rescue ActiveRecord::ConnectionNotEstablished
            nil
          end

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

          # establish_connection has registered the shard in AR's ConnectionHandler.
          # If a post-establish check raises, the pool is returned to neither the
          # caller nor PoolManager — it would be orphaned: live in AR but invisible
          # to the reaper and to max_total accounting (a connection leak that also
          # undercounts the cap). Deregister it before re-raising so AR and the
          # manager stay consistent. The next request re-establishes cleanly.
          begin
            raise(Apartment::PendingMigrationError, tenant) if check_pending_migrations?(pool)

            load_tenant_schema_cache(tenant, pool) if cfg.schema_cache_per_tenant
          rescue StandardError
            Apartment.deregister_shard(pool_key)
            raise
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
        require_relative('../schema_cache')
        cache_path = Apartment::SchemaCache.cache_path_for(tenant)
        return unless File.exist?(cache_path)

        # Bind the pool's reflection to the dump file (Rails 7.1+ API). The
        # removed path-taking SchemaCache#load! raised ArgumentError here:
        # pool.schema_cache returns a BoundSchemaReflection whose #load! takes
        # no args. SchemaReflection.new(path) lazily loads the dump (and Rails
        # version-checks it, ignoring a stale file with a warning).
        pool.schema_reflection =
          ActiveRecord::ConnectionAdapters::SchemaReflection.new(cache_path)
      end
    end
  end
end
