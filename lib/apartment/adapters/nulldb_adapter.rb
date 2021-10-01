# frozen_string_literal: true
require 'apartment/adapters/abstract_adapter'

module Apartment
  module Tenant
    def self.nulldb_adapter(config)
      adapter = Adapters::NullDBAdapter
      adapter.new(config)
    end
  end

  module Adapters
    class NullDBAdapter < AbstractAdapter
      def init; end
    end
  end
end
