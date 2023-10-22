# frozen_string_literal: true
require 'active_record/schema_migration'

module ActiveRecord
  if ActiveRecord::SchemaMigration < ActiveRecord::Base
    class SchemaMigration < ActiveRecord::Base
      class << self
        def table_exists?
          connection.table_exists?(table_name)
        end
      end
    end
  else
    class SchemaMigration
      class << self
        def table_exists?
          connection.table_exists?(table_name)
        end
      end
    end
  end
end