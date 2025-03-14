# frozen_string_literal: true

require 'active_record/connection_adapters/pool_manager'

module Apartment
  module ConnectionAdapters
    # Extends and replaces ActiveRecord's PoolManager class to add Apartment-specific functionality
    class PoolManager < ActiveRecord::ConnectionAdapters::PoolManager
    end
  end
end
