# frozen_string_literal: true

module Apartment
  module ConnectionAdapters
    class ConnectionCounterMap
      extend Forwardable

      def_delegators :counter_map, :values, :each, :keys, :each_pair

      def initialize
        @counter_map = Concurrent::Map.new(initial_capacity: 1)
      end

      def increment(db_config_name)
        counter_for(db_config_name).increment
      end

      def decrement(db_config_name)
        counter_for(db_config_name).decrement
      end

      def value(db_config_name)
        counter_for(db_config_name).value
      end
      alias [] value

      def reset(db_config_name)
        counter_for(db_config_name).reset
      end

      def reset_all
        @counter_map = Concurrent::Map.new(initial_capacity: 1)
      end

      def total_size
        counter_map.values.sum(&:value)
      end

      private

      attr_reader :counter_map

      def counter_for(db_config_name)
        counter_map.compute_if_absent(db_config_name) do
          ConnectionCounter.new
        end
      end
    end
  end
end
