# frozen_string_literal: true

require 'active_record/connection_adapters/pool_config'

module Apartment
  module ConnectionAdapters
    # Extends and replaces ActiveRecord's PoolConfig class to add Apartment-specific functionality
    class PoolConfig < ActiveRecord::ConnectionAdapters::PoolConfig
      # Once we're no longer in Rails 7, we can remove this alias and change
      # calls in the connection handler to only use `connection_descriptor`
      alias connection_descriptor connection_class if ActiveRecord.version < Gem::Version.new('8.0.0')

      # Override to use our own ConnectionPool class
      def pool
        @pool || synchronize { @pool ||= ConnectionAdapters::ConnectionPool.new(self) }
      end
    end
  end
end
