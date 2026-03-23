# frozen_string_literal: true

module Apartment
  module Configs
    # MySQL-specific configuration options.
    # Placeholder for Phase 2 when MySQL adapter is implemented.
    class MySQLConfig
      def initialize
        # No MySQL-specific options yet.
      end

      # Freeze mutable collections (none yet), then freeze self.
      # Symmetric with PostgreSQLConfig#freeze! for consistency.
      def freeze!
        freeze
      end
    end
  end
end
