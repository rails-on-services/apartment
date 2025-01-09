# frozen_string_literal: true

# lib/apartment/adapters/mysql2/base_adapter.rb

# Because this is also extended by the trilogy adapters,
# we can't require mysql2 here, as it would break the trilogy adapter

require_relative '../abstract_adapter'

module Apartment
  module Adapters
    module Mysql2
      class BaseAdapter < AbstractAdapter
        def initialize(config)
          super

          @default_tenant = config[:database]
        end

        protected

        def rescue_from
          Mysql2::Error if defined?(Mysql2)
        end
      end
    end
  end
end
