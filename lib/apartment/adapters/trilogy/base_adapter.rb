# frozen_string_literal: true

# lib/apartment/adapters/trilogy/base_adapter.rb

require_relative '../mysql2/base_adapter'

module Apartment
  module Adapters
    module Trilogy
      class BaseAdapter < Mysql2::BaseAdapter
        protected

        def rescue_from
          Trilogy::Error
        end
      end
    end
  end
end
