# frozen_string_literal: true

module Apartment
  module SchemaDumperPatch
    def self.strip_public_prefix(table_name, include_schemas: [])
      schema, name = table_name.split('.', 2)

      return table_name unless name

      return table_name if schema != 'public' && include_schemas.include?(schema)

      return name if schema == 'public'

      table_name
    end

    def self.apply!
      return unless should_patch?

      ActiveRecord::SchemaDumper.prepend(DumperOverride)
    end

    def self.should_patch?
      return false unless defined?(ActiveRecord::SchemaDumper)

      ActiveRecord.gem_version >= Gem::Version.new('8.1.0')
    end

    module DumperOverride
      private

      def table(table_name, stream)
        include_schemas = Apartment.config&.postgres_config&.include_schemas_in_dump || []
        stripped = SchemaDumperPatch.strip_public_prefix(table_name, include_schemas: include_schemas)
        super(stripped, stream)
      end
    end
  end
end
