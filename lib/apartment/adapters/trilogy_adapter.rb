# frozen_string_literal: true

require_relative 'mysql2_adapter'

module Apartment
  module Adapters
    class TrilogyAdapter < Mysql2Adapter
      # Same behavior as Mysql2Adapter — Trilogy is a compatible MySQL driver.
      # Exception handling differences (Trilogy::Error vs Mysql2::Error)
      # are handled at the connection pool level, not the adapter.
    end
  end
end
