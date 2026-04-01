# frozen_string_literal: true

require 'fileutils'
require_relative 'abstract_adapter'

module Apartment
  module Adapters
    # v4 SQLite3 adapter using file-per-tenant isolation.
    #
    # Resolves tenant-specific connection configs by constructing a database
    # file path from the base config's directory and the environmentified
    # tenant name. SQLite creates the file on first connection, so create_tenant
    # only ensures the directory exists.
    class Sqlite3Adapter < AbstractAdapter
      def resolve_connection_config(tenant, base_config: nil)
        config = base_config || send(:base_config)
        db_dir = config['database'] ? File.dirname(config['database']) : 'db'
        config.merge('database' => File.join(db_dir, "#{environmentify(tenant)}.sqlite3"))
      end

      protected

      def create_tenant(tenant)
        # SQLite creates the file on first connection — just ensure the directory exists.
        FileUtils.mkdir_p(File.dirname(database_file(tenant)))
      end

      def drop_tenant(tenant)
        FileUtils.rm_f(database_file(tenant))
      end

      private

      def database_file(tenant)
        db_dir = base_config['database'] ? File.dirname(base_config['database']) : 'db'
        File.join(db_dir, "#{environmentify(tenant)}.sqlite3")
      end
    end
  end
end
