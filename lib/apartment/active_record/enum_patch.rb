# This makes enum values unique and makes sure we always call create_enum
# instead of checking if it already exists like current Rails 7 code.
module Apartment::PostgreSqlAdapterEnumPatch
  def enum_types
    query = <<~SQL
      SELECT
        type.typname AS name,
        string_agg(enum.enumlabel, ',' ORDER BY enum.enumsortorder) AS value
      FROM pg_enum AS enum
      JOIN pg_type AS type
        ON (type.oid = enum.enumtypid)
      GROUP BY type.typname;
    SQL
    # Make enum values unique since each schema will have the enum declared
    exec_query(query, "SCHEMA").cast_values.map { |name, value| [name, value.split(",").uniq.join(",")] }
  end

  # Taken from https://github.com/alassek/activerecord-pg_enum/blob/6e0daf6/lib/active_record/pg_enum/schema_statements.rb#L14-L18
  def create_enum(name, values)
    execute("CREATE TYPE #{name} AS ENUM (#{Array(values).map { |v| "'#{v}'" }.join(", ")})").tap {
      reload_type_map
    }
  end
end

require 'active_record/connection_adapters/postgresql_adapter'

class ActiveRecord::ConnectionAdapters::PostgreSQLAdapter
  include Apartment::PostgreSqlAdapterEnumPatch
end
