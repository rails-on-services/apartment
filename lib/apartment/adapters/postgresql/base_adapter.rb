# frozen_string_literal: true

require_relative '../abstract_adapter'
require_relative '../../active_record/connection_adapters/postgresql_adapter'

module Apartment
  module Adapters
    module Postgresql
      # Default adapter when not using Postgresql Schemas
      class BaseAdapter < AbstractAdapter
        private

        def rescue_from
          PG::Error
        end
      end
    end
  end
end
