# frozen_string_literal: true

# lib/apartment/adapters.rb

module Apartment
  module Adapters
    module_function

    def mysql2_adapter(config)
      require('mysql2')

      if Apartment.use_schemas
        require_relative('adapters/mysql2/schema_adapter')
        Adapters::Mysql2::SchemaAdapter.new(config)
      else
        require_relative('adapters/mysql2/base_adapter')
        Adapters::Mysql2::BaseAdapter.new(config)
      end
    end

    def postgresql_adapter(config)
      require('pg')

      if Apartment.use_schemas && Apartment.use_sql
        require_relative('adapters/postgresql/schema_from_sql_adapter')
        Adapters::Postgresql::SchemaFromSqlAdapter.new(config)
      elsif Apartment.use_schemas
        require_relative('adapters/postgresql/schema_adapter')
        Adapters::Postgresql::SchemaAdapter.new(config)
      else
        require_relative('adapters/postgresql/base_adapter')
        Adapters::Postgresql::BaseAdapter.new(config)
      end
    end

    # handle postgis adapter as if it were postgresql
    def postgis_adapter(config)
      require('activerecord-postgis-adapter')

      postgresql_adapter(config)
    end

    def sqlite3_adapter(config)
      require('sqlite3')

      require_relative('adapters/sqlite3/base_adapter')
      Adapters::Sqlite3Adapter.new(config)
    end

    def trilogy_adapter(config)
      require('trilogy')

      if Apartment.use_schemas
        require_relative('adapters/trilogy/schema_adapter')
        Apartment::Adapters::Trilogy::SchemaAdapter.new(config)
      else
        require_relative('adapters/trilogy/base_adapter')
        Apartment::Adapters::Trilogy::BaseAdapter.new(config)
      end
    end
  end
end
