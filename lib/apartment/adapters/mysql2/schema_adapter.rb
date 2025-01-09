# frozen_string_literal: true

# lib/apartment/adapters/mysql2/adapter.rb

# This adapter is also extended by the trilogy adapter,
# so we can't require mysql2 here

require_relative 'base_adapter'

module Apartment
  module Adapters
    module Mysql2
      class SchemaAdapter < BaseAdapter
        def initialize(config)
          super

          reset
        end

        #   Reset current tenant to the default_tenant
        #
        def reset
          return unless default_tenant

          Apartment.connection.execute("use `#{default_tenant}`")
        end

        protected

        #   Connect to new tenant
        #
        def connect_to_new(tenant)
          return reset if tenant.nil?

          Apartment.connection.execute("use `#{environmentify(tenant)}`")
        rescue ActiveRecord::StatementInvalid => e
          Apartment::Tenant.reset
          raise_connect_error!(tenant, e)
        end

        def process_excluded_model(model)
          model.constantize.tap do |klass|
            # Ensure that if a schema *was* set, we override
            table_name = klass.table_name.split('.', 2).last

            klass.table_name = "#{default_tenant}.#{table_name}"
          end
        end

        def reset_on_connection_exception?
          true
        end
      end
    end
  end
end
