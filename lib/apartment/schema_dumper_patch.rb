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

      # Rails 8.1+ adds schema-qualified names via `relation_name` in the
      # PG-specific SchemaDumper (PR #50020). The prefix is applied to tables,
      # foreign keys, enums, and indexes — all through `relation_name`. We
      # intercept that single method rather than patching each call site.
      return unless defined?(ActiveRecord::ConnectionAdapters::PostgreSQL::SchemaDumper)

      ActiveRecord::ConnectionAdapters::PostgreSQL::SchemaDumper.prepend(DumperOverride)
    end

    def self.should_patch?
      return false unless defined?(ActiveRecord::SchemaDumper)

      ActiveRecord.gem_version >= Gem::Version.new('8.1.0')
    end

    module DumperOverride
      private

      def relation_name(name)
        result = super
        pg_config = Apartment.config&.postgres_config
        return result unless pg_config

        include_schemas = pg_config.include_schemas_in_dump || []
        SchemaDumperPatch.strip_public_prefix(result, include_schemas: include_schemas)
      end
    end
  end
end
