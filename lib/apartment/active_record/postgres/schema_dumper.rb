# frozen_string_literal: true

# This patch prevents `create_schema` from being added to db/schema.rb as schemas are managed by Apartment
# not ActiveRecord like they would be in a vanilla Rails setup.

require 'active_record/connection_adapters/abstract/schema_dumper'
require 'active_record/connection_adapters/postgresql/schema_dumper'

module ActiveRecord
  module ConnectionAdapters
    module PostgreSQL
      class SchemaDumper
        alias _original_schemas schemas
        def schemas(stream)
          _original_schemas(stream) unless Apartment.use_schemas
        end
      end
    end
  end
end
