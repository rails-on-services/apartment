# frozen_string_literal: true

# lib/apartment/adapters/trilogy/schema_adapter.rb

require_relative '../mysql2/schema_adapter'

module Apartment
  module Adapters
    module Trilogy
      class SchemaAdapter < Mysql2::SchemaAdapter
        protected

        def rescue_from
          Trilogy::Error
        end
      end
    end
  end
end
