# frozen_string_literal: true

module Apartment
  module DatabaseConfigurations
    class << self
      def primary_or_first_db_config
        Apartment.connection_class.configurations.find_db_config(
          ActiveRecord::ConnectionHandling::DEFAULT_ENV.call.to_s
        )
      end

      def resolve_for_tenant(config, tenant: nil,
                             role: ActiveRecord::Base.current_role,
                             shard: ActiveRecord::Base.current_shard)
        case Apartment.config&.tenant_strategy
        when :database_name
          resolve_database_name_for_tenant(config, tenant, role, shard)
        when :schema
          resolve_schema_for_tenant(config, tenant, role, shard)
        when :shard
          resolve_shard_for_tenant(config, tenant, role, shard)
        when :database_config
          resolve_database_config_for_tenant(config, tenant, role, shard)
        else
          {
            db_config: Apartment.connection_class.configurations.resolve(config),
            role:,
            shard:,
          }
        end
      end

      private

      def resolve_schema_for_tenant(config, tenant, role, shard)
        base_db_config = Apartment.connection_class.configurations.resolve(config)
        config_hash = base_db_config.configuration_hash.dup

        config_hash['schema_search_path'] = Apartment.tenant_configs[tenant]

        {
          db_config: HashConfig.new(
            base_db_config.env_name,
            base_db_config.name,
            config_hash,
            tenant
          ),
          role:,
          shard:,
        }
      end

      def resolve_database_name_for_tenant(config, tenant, role, shard)
        base_db_config = Apartment.connection_class.configurations.resolve(config)
        config_hash = base_db_config.configuration_hash.dup

        config_hash['database'] = Apartment.tenant_configs[tenant]

        {
          db_config: HashConfig.new(
            base_db_config.env_name,
            base_db_config.name,
            config_hash,
            tenant
          ),
          role:,
          shard:,
        }
      end

      def resolve_shard_for_tenant(config, tenant, role, shard)
        base_db_config = Apartment.connection_class.configurations.resolve(config)
        config_hash = base_db_config.configuration_hash.dup

        {
          db_config: HashConfig.new(
            base_db_config.env_name,
            base_db_config.name,
            config_hash,
            tenant
          ),
          role:,
          shard: Apartment.tenant_configs[tenant] || shard,
        }
      end

      def resolve_database_config_for_tenant(config, tenant, role, shard)
        base_db_config = Apartment.connection_class.configurations.resolve(config)
        config_hash = base_db_config.configuration_hash.dup
        tenant_config = Apartment.tenant_configs[tenant]

        config_hash.merge!(tenant_config) unless config_hash.eql?(tenant_config)

        {
          db_config: HashConfig.new(
            base_db_config.env_name,
            base_db_config.name,
            config_hash,
            tenant
          ),
          role:,
          shard:,
        }
      end
    end
  end
end
