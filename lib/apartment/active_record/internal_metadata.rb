# frozen_string_literal: true

class InternalMetadata < ActiveRecord::Base # :nodoc:
  class << self
    def table_exists?
      connection.schema_cache.data_source_exists?(table_name)
    end
    alias :table_name :name
  end
end
