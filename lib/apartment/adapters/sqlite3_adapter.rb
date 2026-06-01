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

      # No missing-tenant fail-safe override on purpose — keep the conservative
      # AbstractAdapter default (failsafe_error_classes == []). SQLite gives no
      # sound "container gone" signal: connecting to a dropped file auto-recreates
      # it empty, so by the time the elevator's rescue runs File.exist? is true
      # and the only query error is "no such table" (StatementInvalid) — identical
      # to a missing table in a live tenant, or to a freshly created tenant with
      # no schema loaded (schema_load_strategy nil). A zero-tables heuristic would
      # 404 valid-but-empty tenants; there is no authoritative catalog (unlike
      # pg_database / information_schema) to distinguish dropped from unpopulated.
      # Auto-create is also load-bearing — create_tenant relies on it — so it
      # cannot be disabled to force a clean missing-file error. SQLite file-per-
      # tenant is a dev/test strategy, not a multi-process target, so the
      # cross-process drop gap this guards barely applies. See the design doc.

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
