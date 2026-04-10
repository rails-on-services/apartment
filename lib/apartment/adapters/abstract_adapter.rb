# frozen_string_literal: true

require 'active_support/callbacks'
require 'active_support/core_ext/string/inflections'
require_relative '../tenant_name_validator'

module Apartment
  module Adapters
    class AbstractAdapter # rubocop:disable Metrics/ClassLength
      include ActiveSupport::Callbacks

      define_callbacks :create, :switch

      # The raw database connection configuration hash (from ActiveRecord).
      # Not to be confused with Apartment.config (the Apartment::Config object).
      attr_reader :connection_config

      def initialize(connection_config)
        @connection_config = connection_config
      end

      # Template method: validates tenant name then delegates to resolve_connection_config.
      # Called by ConnectionHandling — subclasses should NOT override this.
      # base_config_override: when supplied (e.g. a role-specific config from ConnectionHandling),
      # the adapter builds the tenant config on top of it instead of its own base_config.
      def validated_connection_config(tenant, base_config_override: nil)
        effective_base = base_config_override || base_config
        TenantNameValidator.validate!(
          tenant,
          strategy: Apartment.config.tenant_strategy,
          adapter_name: effective_base['adapter']
        )
        resolve_connection_config(tenant, base_config: effective_base)
      end

      # Resolve a tenant-specific connection config hash.
      # Subclasses override to set strategy-specific keys.
      def resolve_connection_config(tenant, base_config: nil)
        raise(NotImplementedError)
      end

      # Create a new tenant (schema or database).
      def create(tenant)
        TenantNameValidator.validate!(
          environmentify(tenant),
          strategy: Apartment.config.tenant_strategy,
          adapter_name: base_config['adapter']
        )
        run_callbacks(:create) do
          create_tenant(tenant)
          grant_tenant_privileges(tenant)
          import_schema(tenant) if Apartment.config.schema_load_strategy
          seed(tenant) if Apartment.config.seed_after_create
          Instrumentation.instrument(:create, tenant: tenant)
        end
      end

      # Drop a tenant.
      def drop(tenant) # rubocop:disable Metrics/CyclomaticComplexity
        drop_tenant(tenant)
        removed_pools = Apartment.pool_manager&.remove_tenant(tenant) || []
        removed_pools.each do |pool_key, pool|
          begin
            pool&.disconnect! if pool.respond_to?(:disconnect!)
          rescue StandardError => e
            warn "[Apartment] Pool disconnect failed for '#{pool_key}': #{e.class}: #{e.message}"
          end
          begin
            deregister_shard_from_ar_handler(pool_key)
          rescue StandardError => e
            warn "[Apartment] Shard deregistration failed for '#{pool_key}': #{e.class}: #{e.message}"
          end
        end
        Instrumentation.instrument(:drop, tenant: tenant)
      end

      # Run migrations for a tenant.
      def migrate(tenant, version = nil)
        Apartment::Tenant.switch(tenant) do
          ActiveRecord::Base.connection_pool.migration_context.migrate(version)
        end
      end

      # Run seeds for a tenant.
      def seed(tenant)
        Apartment::Tenant.switch(tenant) do
          seed_file = Apartment.config.seed_data_file
          return unless seed_file

          unless File.exist?(seed_file)
            raise(Apartment::ConfigurationError,
                  "Seed file '#{seed_file}' does not exist")
          end

          load(seed_file)
        end
      end

      # Whether pinned models can share the tenant's connection pool using
      # qualified table names instead of establish_connection.
      #
      # Returns false by default (separate pool). Subclasses override to
      # return true when the engine supports cross-schema/database queries,
      # gated by config.force_separate_pinned_pool.
      def shared_pinned_connection?
        false
      end

      # Qualify a pinned model's table_name so it targets the default
      # tenant's tables from any tenant connection. Subclasses must
      # implement when shared_pinned_connection? returns true.
      def qualify_pinned_table_name(_klass)
        raise(NotImplementedError,
              "#{self.class}#qualify_pinned_table_name must be implemented when shared_pinned_connection? is true")
      end

      # Process all pinned models. When shared_pinned_connection? is true, qualifies
      # table names for shared pool routing. Otherwise, establishes separate connections.
      def process_pinned_models
        return if Apartment.pinned_models.empty?

        Apartment.pinned_models.each do |klass|
          process_pinned_model(klass)
        rescue StandardError => e
          raise(Apartment::ConfigurationError,
                "Failed to process pinned model #{klass.name}: #{e.class}: #{e.message}")
        end
      end

      # Process a single pinned model. Called by process_pinned_models (batch)
      # and by Apartment::Model.pin_tenant (when activated? is true).
      #
      # When shared_pinned_connection? is true, qualifies the table name so
      # the model uses the tenant's pool (preserving transactional integrity).
      # Otherwise, establishes a separate connection pool (required when
      # cross-database queries are impossible).
      def process_pinned_model(klass)
        return if klass.instance_variable_get(:@apartment_pinned_processed)

        if shared_pinned_connection?
          qualify_pinned_table_name(klass)
        else
          klass.establish_connection(pinned_model_config)
        end

        klass.instance_variable_set(:@apartment_pinned_processed, true)
      end

      # Deprecated: use process_pinned_models instead.
      def process_excluded_models
        warn '[Apartment] DEPRECATION: process_excluded_models is deprecated. ' \
             'Use Apartment::Model with pin_tenant instead.'
        process_pinned_models
      end

      # Environmentify a tenant name based on config.
      # :prepend/:append require Rails to be defined (for Rails.env).
      def environmentify(tenant)
        case Apartment.config.environmentify_strategy
        when :prepend
          "#{rails_env}_#{tenant}"
        when :append
          "#{tenant}_#{rails_env}"
        when nil
          tenant.to_s
        else
          # Callable
          Apartment.config.environmentify_strategy.call(tenant)
        end
      end

      # Default tenant from config.
      def default_tenant
        Apartment.config.default_tenant
      end

      protected

      def create_tenant(tenant)
        raise(NotImplementedError)
      end

      def drop_tenant(tenant)
        raise(NotImplementedError)
      end

      private

      def grant_tenant_privileges(tenant)
        app_role = Apartment.config.app_role
        return unless app_role

        conn = ActiveRecord::Base.connection
        if app_role.respond_to?(:call)
          app_role.call(tenant, conn)
        else
          grant_privileges(tenant, conn, app_role)
        end
      end

      # No-op base implementation — PG schema and MySQL adapters override.
      def grant_privileges(tenant, connection, role_name)
        # intentional no-op
      end

      # Connection config with string keys (used by subclasses to build tenant configs).
      def base_config
        connection_config.transform_keys(&:to_s)
      end

      # Connection config for pinned models on the separate-pool path.
      # For schema strategy, pins schema_search_path to the default tenant
      # (plus persistent schemas) so the connection resolves tables and FK
      # constraints in the correct schema.
      # For database strategies, returns base_config unchanged.
      def pinned_model_config
        config = base_config
        return config unless Apartment.config.tenant_strategy == :schema

        persistent = Apartment.config.postgres_config&.persistent_schemas || []
        search_path = [default_tenant, *persistent].map { |s| %("#{s}") }.join(',')
        config.merge('schema_search_path' => search_path)
      end

      # Detect whether a model has an explicit self.table_name = assignment
      # (as opposed to Rails' lazy convention computation). Returns false if
      # the explicit value matches what convention would produce, since the
      # convention path handles that case correctly.
      # NOTE: compute_table_name is a private Rails API; tested against Rails
      # main as a canary in CI (see .github/workflows/ci.yml).
      def explicit_table_name?(klass)
        return false unless klass.instance_variable_defined?(:@table_name)

        cached = klass.instance_variable_get(:@table_name)
        computed = klass.send(:compute_table_name)
        cached != computed
      end

      def rails_env
        unless defined?(Rails)
          raise(Apartment::ConfigurationError,
                'environmentify_strategy :prepend/:append requires Rails to be defined')
        end
        Rails.env
      end

      def deregister_shard_from_ar_handler(pool_key)
        Apartment.deregister_shard(pool_key)
      end

      def import_schema(tenant)
        Apartment::Tenant.switch(tenant) do
          schema_file = resolve_schema_file
          case Apartment.config.schema_load_strategy
          when :schema_rb
            load(schema_file)
          when :sql
            ActiveRecord::Tasks::DatabaseTasks.load_schema(
              ActiveRecord::Base.connection_db_config, :sql, schema_file
            )
          end
        end
      rescue StandardError => e
        raise(Apartment::SchemaLoadError,
              "Failed to load schema for tenant '#{tenant}': #{e.class}: #{e.message}")
      end

      def resolve_schema_file
        custom = Apartment.config.schema_file
        return custom if custom

        if defined?(Rails) && Rails.respond_to?(:root) && Rails.root
          Rails.root.join('db/schema.rb').to_s
        else
          'db/schema.rb'
        end
      end
    end
  end
end
