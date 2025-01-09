# frozen_string_literal: true

# lib/apartment/patches/postgresql/schema_dumper.rb

module Apartment
  module Patches
    module Postgresql
      module SchemaDumper
        # Override schemas method to skip schema dumping when Apartment manages schemas
        def schemas(stream)
          super unless Apartment.use_schemas
        end
      end
    end
  end
end

# Apply the patch to ActiveRecord's PostgreSQL SchemaDumper
ActiveSupport.on_load(:active_record) do
  ActiveRecord::ConnectionAdapters::PostgreSQL::SchemaDumper.prepend(Apartment::Patches::Postgresql::SchemaDumper)
end
