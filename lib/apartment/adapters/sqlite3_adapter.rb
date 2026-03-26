# frozen_string_literal: true

require 'fileutils'
require_relative 'abstract_adapter'

module Apartment
  module Adapters
    class SQLite3Adapter < AbstractAdapter
      def resolve_connection_config(tenant)
        base_config.merge('database' => database_file(tenant))
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
