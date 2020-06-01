# frozen_string_literal: true

module Apartment
  module Capabilities
    module ApartmentManager
      #   Create a new tenant, import schema, seed if appropriate
      #
      #   @param {String} tenant Tenant name
      #
      def create(tenant)
        run_callbacks :create do
          create_tenant(tenant)

          switch(tenant) do
            import_database_schema

            # Seed data if appropriate
            seed_data if Apartment.seed_after_create

            yield if block_given?
          end
        end
      end

      #   Initialize Apartment config options such as excluded_models
      #
      def init
        process_excluded_models
        Apartment.connection.schema_search_path = full_search_path
      end

      def current
        @current || default_tenant
      end

      #   Return the original public tenant
      #
      #   @return {String} default tenant name
      #
      def default_tenant
        @default_tenant || Apartment.default_tenant
      end

      #   Drop the tenant
      #
      #   @param {String} tenant name
      #
      def drop(tenant)
        with_neutral_connection(tenant) do |conn|
          drop_command(conn, tenant)
        end
      rescue *rescuable_exceptions => e
        raise_drop_tenant_error!(tenant, e)
      end

      #   Switch to a new tenant
      #
      #   @param {String} tenant name
      #
      def switch!(tenant = nil)
        run_callbacks :switch do
          connect_to_new(tenant).tap do
            Apartment.connection.clear_query_cache
          end
        end
        tenant
      end

      #   Connect to tenant, do your biz, switch back to previous tenant
      #
      #   @param {String?} tenant to connect to
      #
      def switch(tenant = nil)
        previous_tenant = current
        switch!(tenant)
        yield
      ensure
        begin
          switch!(previous_tenant)
        rescue StandardError => _e
          reset
        end
      end

      #   Iterate over all tenants, switch to tenant and yield tenant name
      #
      def each(tenants = Apartment.tenant_names)
        tenants.each do |tenant|
          switch(tenant) { yield tenant }
        end
      end

      #   Establish a new connection for each specific excluded model
      #
      def process_excluded_models
        # All other models will shared a connection (at Apartment.connection_class)
        # and we can modify at will
        Apartment.excluded_models.each do |excluded_model|
          process_excluded_model(excluded_model)
        end
      end

      #   Reset schema search path to the default schema_search_path
      #
      #   @return {String} default schema search path
      #
      def reset
        @current = default_tenant
        Apartment.connection.schema_search_path = full_search_path
        reset_sequence_names
      end

      #   Load the rails seed file into the db
      #
      def seed_data
        # Don't log the output of seeding the db
        silence_warnings { load_or_raise(Apartment.seed_data_file) } if Apartment.seed_data_file
      end

      #   Prepend the environment if configured and the environment isn't already there
      #
      #   @param {String} tenant Database name
      #   @return {String} tenant name with Rails environment *optionally* prepended
      #
      def environmentify(tenant)
        return tenant if tenant.nil? || tenant.include?(Rails.env)

        if Apartment.prepend_environment
          "#{Rails.env}_#{tenant}"
        elsif Apartment.append_environment
          "#{tenant}_#{Rails.env}"
        else
          tenant
        end
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

      #   Create the tenant
      #
      #   @param {String} tenant Database name
      #
      def create_tenant(tenant)
        with_neutral_connection(tenant) do |conn|
          create_tenant_command(conn, tenant)
        end
      rescue *rescuable_exceptions => e
        raise_create_tenant_error!(tenant, e)
      end

      #   Set schema search path to new schema
      #
      def connect_to_new(tenant = nil)
        return reset if tenant.nil?

        tenant = tenant.to_s
        raise ActiveRecord::StatementInvalid, "Could not find schema #{tenant}" unless tenant_exists?(tenant)

        @current = tenant
        Apartment.connection.schema_search_path = full_search_path

        # When the PostgreSQL version is < 9.3,
        # there is a issue for prepared statement with changing search_path.
        # https://www.postgresql.org/docs/9.3/static/sql-prepare.html
        Apartment.connection.clear_cache! if postgresql_version < 90_300
        reset_sequence_names
      rescue *rescuable_exceptions
        raise TenantNotFound, "One of the following schema(s) is invalid: \"#{tenant}\" #{full_search_path}"
      end

      #   Load a file or raise error if it doesn't exists
      #
      def load_or_raise(file)
        raise FileNotFound, "#{file} doesn't exist yet" unless File.exist?(file)

        load(file)
      end

      #   Exceptions to rescue from on db operations
      #
      def rescuable_exceptions
        [ActiveRecord::ActiveRecordError] + Array(rescue_from)
      end

      #   Extra exceptions to rescue from
      #
      def rescue_from
        []
      end

      def raise_drop_tenant_error!(tenant, exception)
        raise TenantNotFound, "Error while dropping tenant #{environmentify(tenant)}: #{exception.message}"
      end

      def raise_create_tenant_error!(tenant, exception)
        raise TenantExists, "Error while creating tenant #{environmentify(tenant)}: #{exception.message}"
      end

      def raise_connect_error!(tenant, exception)
        raise TenantNotFound, "Error while connecting to tenant #{environmentify(tenant)}: #{exception.message}"
      end

      private

      def tenant_exists?(tenant)
        return true unless Apartment.tenant_presence_check

        Apartment.connection.schema_exists?(tenant)
      end

      def create_tenant_command(conn, tenant)
        conn.execute(%(CREATE SCHEMA "#{tenant}"))
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
        # ActiveRecord::ConnectionAdapters::PostgreSQLAdapter#postgresql_version is
        # public from Rails 5.0.
        Apartment.connection.send(:postgresql_version)
      end

      def reset_sequence_names
        # sequence_name contains the schema, so it must be reset after switch
        # There is `reset_sequence_name`, but that method actually goes to the database
        # to find out the new name. Therefore, we do this hack to only unset the name,
        # and it will be dynamically found the next time it is needed
        ActiveRecord::Base.descendants
                          .select { |c| c.instance_variable_defined?(:@sequence_name) }
                          .reject { |c| c.instance_variable_defined?(:@explicit_sequence_name) && c.instance_variable_get(:@explicit_sequence_name) }
                          .each do |c|
                            c.remove_instance_variable :@sequence_name
                          end
      end
    end
  end
end
