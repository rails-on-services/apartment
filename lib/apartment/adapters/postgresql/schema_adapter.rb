# frozen_string_literal: true

# lib/apartment/adapters/postgresql/schema_adapter.rb

require_relative 'base_adapter'

module Apartment
  module Adapters
    module Postgresql
      # Separate Adapter for Postgresql when using schemas
      class SchemaAdapter < BaseAdapter
        def initialize(config)
          super

          reset
        end

        def default_tenant
          @default_tenant = Apartment.default_tenant || 'public'
        end

        #   Reset schema search path to the default schema_search_path
        #
        #   @return {String} default schema search path
        #
        def reset
          @current = default_tenant
          Apartment.connection.schema_search_path = full_search_path
        end

        def init
          super
          Apartment.connection.schema_search_path = full_search_path
        end

        def current
          @current || default_tenant
        end

        protected

        def process_excluded_model(excluded_model)
          excluded_model.constantize.tap do |klass|
            # Ensure that if a schema *was* set, we override
            table_name = klass.table_name.split('.', 2).last

            klass.table_name = "#{default_tenant}.#{table_name}"
          end
        end

        def drop_command(conn, tenant)
          conn.execute(%(DROP SCHEMA "#{tenant}" CASCADE))
        end

        #   Set schema search path to new schema
        #
        def connect_to_new(tenant = nil)
          return reset if tenant.nil?
          raise(ActiveRecord::StatementInvalid, "Could not find schema #{tenant}") unless schema_exists?(tenant)

          @current = tenant.is_a?(Array) ? tenant.map(&:to_s) : tenant.to_s
          Apartment.connection.schema_search_path = full_search_path
        rescue *rescuable_exceptions => e
          raise_schema_connect_to_new(tenant, e)
        end

        private

        def tenant_exists?(tenant)
          return true unless Apartment.tenant_presence_check

          Apartment.connection.schema_exists?(tenant)
        end

        def create_tenant_command(conn, tenant)
          # NOTE: This was causing some tests to fail because of the database strategy for rspec
          if ActiveRecord::Base.connection.open_transactions.positive?
            conn.execute(%(CREATE SCHEMA "#{tenant}"))
          else
            schema = %(BEGIN;
          CREATE SCHEMA "#{tenant}";
          COMMIT;)

            conn.execute(schema)
          end
        rescue *rescuable_exceptions => e
          rollback_transaction(conn)
          raise(e)
        end

        def rollback_transaction(conn)
          conn.execute('ROLLBACK;')
        end

        #   Generate the final search path to set including persistent_schemas
        #
        def full_search_path
          persistent_schemas.map(&:inspect).join(', ')
        end

        def persistent_schemas
          [@current, Apartment.persistent_schemas].flatten
        end

        def postgresql_version
          Apartment.connection.postgresql_version
        end

        def schema_exists?(schemas)
          return true unless Apartment.tenant_presence_check

          Array(schemas).all? { |schema| Apartment.connection.schema_exists?(schema.to_s) }
        end

        def raise_schema_connect_to_new(tenant, exception)
          raise(TenantNotFound, <<~EXCEPTION_MESSAGE)
            Could not set search path to schemas, they may be invalid: "#{tenant}" #{full_search_path}.
            Original error: #{exception.class}: #{exception}
          EXCEPTION_MESSAGE
        end
      end
    end
  end
end
