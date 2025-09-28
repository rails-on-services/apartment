# frozen_string_literal: true

require 'active_record/connection_adapters/abstract/connection_pool'

module Apartment
  module ConnectionAdapters
    # Extends and replaces ActiveRecord's ConnectionPool class to add Apartment-specific functionality
    class ConnectionPool < ActiveRecord::ConnectionAdapters::ConnectionPool
      attr_reader :apt_max_connections

      def initialize(pool_config)
        super
        @apt_max_connections = pool_config.db_config.configuration_hash[:apt_max_connections] || Float::INFINITY
      end

      # Override
      # Check-in a database connection back into the pool, indicating that you
      # no longer need this connection.
      #
      # +conn+: an AbstractAdapter object, which was obtained by earlier by
      # calling #checkout on this pool.
      def checkin(conn)
        super
        GLOBAL_CONNECTION_COUNTER_MAP.decrement(db_config.name)
      end

      # Override
      # If the pool is not at a <tt>@size</tt> limit, establish new connection. Connecting
      # to the DB is done outside main synchronized section.
      #--
      # Implementation constraint: a newly established connection returned by this
      # method must be in the +.leased+ state.
      def try_to_checkout_new_connection
        # first in synchronized section check if establishing new conns is allowed
        # and increment @now_connecting, to prevent overstepping this pool's @size
        # constraint
        do_checkout = synchronize do
          # This is the main change from the original method
          @now_connecting += 1 if can_connect_more?
        end
        return unless do_checkout

        begin
          # if successfully incremented @now_connecting establish new connection
          # outside of synchronized section
          conn = checkout_new_connection
        ensure
          synchronize do
            if conn
              adopt_connection(conn)
              # returned conn needs to be already leased
              conn.lease
            end
            @now_connecting -= 1
          end
        end
      end

      # Are we allowed to establish a new connection?
      def can_connect_more?
        @threads_blocking_new_connections.zero? &&
          (@connections.size + @now_connecting) < @size &&
          (GLOBAL_CONNECTION_COUNTER_MAP[db_config.name] + @now_connecting) < @apt_max_connections
      end

      # Override
      # Establishes a new connection to the database outside of a synchronized section.
      def checkout_new_connection
        conn = super
        GLOBAL_CONNECTION_COUNTER_MAP.increment(db_config.name)
        conn
      end
    end
  end
end
