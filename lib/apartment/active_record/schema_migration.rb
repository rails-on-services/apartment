# frozen_string_literal: true

require 'active_record/schema_migration'

module ActiveRecord
  class SchemaMigration # :nodoc:
    class << self
      def table_exists?
        connection.table_exists?(table_name)
      end
      alias :table_name :name
    end
  end
end

# TODO: required only for ransack < 4.1
class Arel::Table
  alias :table_name :name
end
