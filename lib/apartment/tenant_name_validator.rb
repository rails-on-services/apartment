# frozen_string_literal: true

module Apartment
  module TenantNameValidator
    module_function

    # Validate a tenant name against common and engine-specific rules.
    # Raises ConfigurationError on invalid names. Pure in-memory check — no IO.
    def validate!(name, strategy:, adapter_name: nil)
      validate_common!(name)
      case strategy
      when :schema
        validate_postgresql_identifier!(name)
      when :database_name
        validate_for_adapter!(name, adapter_name)
      end
      # :shard and :database_config use common validation only (not yet implemented).
    end

    # --- Common rules (all engines) ---

    def validate_common!(name)
      raise(ConfigurationError, 'Tenant name must be a String') unless name.is_a?(String)
      raise(ConfigurationError, 'Tenant name cannot be empty') if name.empty?
      raise(ConfigurationError, "Tenant name contains NUL byte: #{name.inspect}") if name.include?("\x00")
      raise(ConfigurationError, "Tenant name contains whitespace: #{name.inspect}") if name.match?(/\s/)
      return unless name.length > 255

      raise(ConfigurationError, "Tenant name too long (#{name.length} chars, max 255): #{name.inspect}")
    end

    # --- PostgreSQL identifiers (schema names, database names) ---
    # Hyphens are allowed — our adapters quote via quote_table_name.
    # Cannot start with pg_ (reserved prefix).

    def validate_postgresql_identifier!(name)
      if name.length > 63
        raise(ConfigurationError, "PostgreSQL identifier too long (#{name.length} chars, max 63): #{name.inspect}")
      end
      unless name.match?(/\A[a-zA-Z_][a-zA-Z0-9_-]*\z/)
        raise(ConfigurationError,
              "Invalid PostgreSQL identifier: #{name.inspect}. " \
              'Must start with letter/underscore, contain only letters, digits, underscores, hyphens')
      end
      return unless name.start_with?('pg_')

      raise(ConfigurationError, "Tenant name cannot start with 'pg_' (reserved prefix): #{name.inspect}")
    end

    # --- MySQL database names ---
    # Max 64 chars, allowed: [a-zA-Z0-9_$-], no leading digit, no trailing dot.

    def validate_mysql_database_name!(name)
      if name.length > 64
        raise(ConfigurationError, "MySQL database name too long (#{name.length} chars, max 64): #{name.inspect}")
      end
      raise(ConfigurationError, "MySQL database name cannot start with a digit: #{name.inspect}") if name.match?(/\A\d/)
      raise(ConfigurationError, "MySQL database name cannot end with a period: #{name.inspect}") if name.end_with?('.')
      return unless name.match?(/[^a-zA-Z0-9_$-]/)

      raise(ConfigurationError,
            "Invalid MySQL database name: #{name.inspect}. " \
            'Allowed characters: letters, digits, underscore, dollar sign, hyphen')
    end

    # --- SQLite file paths ---
    # No path traversal, filesystem-safe characters.

    def validate_sqlite_path!(name)
      raise(ConfigurationError, "SQLite tenant name contains path traversal: #{name.inspect}") if name.include?('..')
      return unless name.match?(%r{[/\\]})

      raise(ConfigurationError, "SQLite tenant name contains path separators: #{name.inspect}")
    end

    # --- Dispatcher for :database_name strategy ---

    def validate_for_adapter!(name, adapter_name)
      case adapter_name
      when /mysql/i, /trilogy/i then validate_mysql_database_name!(name)
      when /postgresql/i, /postgis/i then validate_postgresql_identifier!(name)
      when /sqlite/i then validate_sqlite_path!(name)
      end
    end
  end
end
