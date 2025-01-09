# frozen_string_literal: true

require_relative 'schema_adapter'

module Apartment
  module Adapters
    module Postgresql
      # Another Adapter for Postgresql when using schemas and SQL
      class SchemaFromSqlAdapter < SchemaAdapter
        PSQL_DUMP_BLACKLISTED_STATEMENTS = [
          /SET search_path/i,                           # overridden later
          /SET lock_timeout/i,                          # new in postgresql 9.3
          /SET row_security/i,                          # new in postgresql 9.5
          /SET idle_in_transaction_session_timeout/i,   # new in postgresql 9.6
          /SET default_table_access_method/i,           # new in postgresql 12
          /CREATE SCHEMA/i,
          /COMMENT ON SCHEMA/i,
          /SET transaction_timeout/i,                   # new in postgresql 17

        ].freeze

        def import_database_schema
          preserving_search_path do
            clone_pg_schema
            copy_schema_migrations
          end
        end

        private

        # Re-set search path after the schema is imported.
        # Postgres now sets search path to empty before dumping the schema
        # and it mut be reset
        #
        def preserving_search_path
          search_path = Apartment.connection.execute('show search_path').first['search_path']
          yield
          Apartment.connection.execute("set search_path = #{search_path}")
        end

        # Clone default schema into new schema named after current tenant
        #
        def clone_pg_schema
          pg_schema_sql = patch_search_path(pg_dump_schema)
          Apartment.connection.execute(pg_schema_sql)
        end

        # Copy data from schema_migrations into new schema
        #
        def copy_schema_migrations
          pg_migrations_data = patch_search_path(pg_dump_schema_migrations_data)
          Apartment.connection.execute(pg_migrations_data)
        end

        #   Dump postgres default schema
        #
        #   @return {String} raw SQL containing only postgres schema dump
        #
        def pg_dump_schema
          exclude_table =
            if Apartment.pg_exclude_clone_tables
              excluded_tables.map! { |t| "-T #{t}" }.join(' ')
            else
              ''
            end
          with_pg_env { `pg_dump -s -x -O -n #{default_tenant} #{dbname} #{exclude_table}` }
        end

        #   Dump data from schema_migrations table
        #
        #   @return {String} raw SQL containing inserts with data from schema_migrations
        #
        def pg_dump_schema_migrations_data
          with_pg_env do
            `pg_dump -a --inserts -t #{default_tenant}.schema_migrations -t #{default_tenant}.ar_internal_metadata #{dbname}`
          end
        end

        # Temporary set Postgresql related environment variables if there are in @config
        #
        def with_pg_env # rubocop:disable Metrics/AbcSize
          pghost = ENV.fetch('PGHOST', nil)
          pgport = ENV.fetch('PGPORT', nil)
          pguser = ENV.fetch('PGUSER', nil)
          pgpassword = ENV.fetch('PGPASSWORD', nil)

          ENV['PGHOST'] = @config[:host] if @config[:host]
          ENV['PGPORT'] = @config[:port].to_s if @config[:port]
          ENV['PGUSER'] = @config[:username].to_s if @config[:username]
          ENV['PGPASSWORD'] = @config[:password].to_s if @config[:password]

          yield
        ensure
          ENV['PGHOST'] = pghost
          ENV['PGPORT'] = pgport
          ENV['PGUSER'] = pguser
          ENV['PGPASSWORD'] = pgpassword
        end

        #   Remove "SET search_path ..." line from SQL dump and prepend search_path set to current tenant
        #
        #   @return {String} patched raw SQL dump
        #
        def patch_search_path(sql)
          search_path = "SET search_path = \"#{current}\", #{default_tenant};"

          swap_schema_qualifier(sql)
            .split("\n")
            .select { |line| check_input_against_regexps(line, PSQL_DUMP_BLACKLISTED_STATEMENTS).empty? }
            .prepend(search_path)
            .join("\n")
        end

        def swap_schema_qualifier(sql)
          sql.gsub(/#{default_tenant}\.\w*/) do |match|
            if Apartment.pg_excluded_names.any? { |name| match.include?(name) } ||
               (Apartment.pg_exclude_clone_tables && excluded_tables.any?(match))
              match
            else
              match.gsub("#{default_tenant}.", %("#{current}".))
            end
          end
        end

        #   Checks if any of regexps matches against input
        #
        def check_input_against_regexps(input, regexps)
          regexps.select { |c| input.match(c) }
        end

        # Convenience method for excluded table names
        #
        def excluded_tables
          Apartment.excluded_models.map do |m|
            m.constantize.table_name
          end
        end

        # Convenience method for current database name
        #
        def dbname
          Apartment.connection_config[:database]
        end
      end
    end
  end
end
