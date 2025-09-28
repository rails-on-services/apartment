# frozen_string_literal: true

module Apartment
  module Tenants
    class ConfigurationMap
      extend Forwardable

      def_delegators :configuration_map, :values, :each, :keys, :each_pair

      def initialize
        @configuration_map = Concurrent::Map.new(initial_capacity: 1)
        @primary_db_config = Apartment::DatabaseConfigurations.primary_or_first_db_config
      end

      def [](given_tenant)
        tenant = given_tenant.presence || Apartment.config.default_tenant
        configuration_map.compute_if_absent(tenant) do
          # If tenant not found and strategy is database_config, return the primary database config
          # Otherwise, environmentify the tenant name
          case Apartment.config.tenant_strategy
          when :database_config
            primary_db_config.configuration_hash
          else
            environmentify_tenant(tenant)
          end
        end
      end

      def add_or_replace(tenant_config)
        tenant_name = tenant_name_from_config(tenant_config)

        stored_config = configuration_map.compute(tenant_name) do |existing_tenant_config|
          if existing_tenant_config.nil?
            Logger.debug { "Inserting new tenant config for #{tenant_name}" }
          else
            Logger.debug { "Tenant config for #{tenant_name} already exists, replacing it" }
          end

          case Apartment.config.tenant_strategy
          when :database_config
            tenant_config[:database]
          else
            environmentify_tenant(tenant_config, tenant_strategy: Apartment.config.tenant_strategy)
          end
        end

        { name: tenant_name, config: stored_config }
      end

      private

      attr_reader :configuration_map, :primary_db_config

      def tenant_name_from_config(tenant_config)
        case tenant_config
        when Hash
          tenant_config[:name]
        when String
          tenant_config
        else
          raise(ConfigurationError,
                "Tenant configuration must be String or Hash, not #{tenant_config.class}")
        end
      end

      def environmentify_tenant(tenant_config, tenant_strategy: nil)
        tenant = if tenant_config.is_a?(Hash)
                   tenant_config[tenant_strategy]
                 else
                   tenant_config
                 end

        tenant_with_env = case Apartment.config.environmentify_strategy
                          when :prepend
                            "#{Rails.env}_#{tenant}"
                          when :append
                            "#{tenant}_#{Rails.env}"
                          when nil
                            tenant
                          else
                            Apartment.config.environmentify_strategy.call(tenant)
                          end

        quote_tenant_name(tenant_with_env)
      end

      if ActiveRecord.version < Gem::Version.new('7.2.0')
        def tenant_quote_strategy
          @tenant_quote_strategy ||= case primary_db_config.adapter
                                     when 'mysql2', 'trilogy'
                                       :backtick
                                     else
                                       :double_quote
                                     end
        end

        def quote_tenant_name(tenant_name)
          case tenant_quote_strategy
          when :backtick
            %(`#{tenant_name}`)
          else
            %("#{tenant_name}")
          end
        end
      else
        def quote_tenant_name(tenant_name)
          primary_db_config.adapter_class.quote_table_name(tenant_name)
        end
      end
    end
  end
end
