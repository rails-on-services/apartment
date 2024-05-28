# frozen_string_literal: true

require 'apartment/adapters/mysql2_adapter'

module Apartment
  # Helper module to decide wether to use trilogy adapter or trilogy adapter with schemas
  module Tenant
    def self.trilogy_adapter(config)
      if Apartment.use_schemas
        Adapters::TrilogySchemaAdapter.new(config)
      else
        Adapters::TrilogyAdapter.new(config)
      end
    end
  end

  module Adapters
    class TrilogyAdapter < Mysql2Adapter
      protected

      def rescue_from
        Trilogy::Error
      end
    end

    class TrilogySchemaAdapter < Mysql2SchemaAdapter
    end
  end
end
