# frozen_string_literal: true

module Apartment
  module ConnectionAdapters
    class ConnectionCounter
      extend Forwardable

      def initialize
        @counter = Concurrent::AtomicFixnum.new(0)
      end

      def_delegators :counter, :increment, :decrement, :value

      def reset
        counter.value = 0
      end

      private

      attr_reader :counter
    end
  end
end
