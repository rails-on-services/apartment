# frozen_string_literal: true

require 'active_record/schema_migration'

module ActiveRecord
  class SchemaMigration # :nodoc:
    class << self
      def table_exists?
        connection.table_exists?(table_name)
      end
    end
  end
end
