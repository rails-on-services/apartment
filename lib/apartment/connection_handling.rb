# frozen_string_literal: true

module Apartment
  # ConnectionHandling utility module to help with connection methods across Rails versions
  module ConnectionHandling
    module_function

    # Returns true if the current Rails version supports lease_connection and with_connection natively
    def modern_connection_handling?
      ActiveRecord.version.release >= Gem::Version.new('6.0')
    end

    # For tenant switching operations where the connection needs to persist
    # Uses lease_connection in Rails 6+ or connection in older Rails
    def lease_apartment_connection
      if modern_connection_handling?
        Apartment.lease_connection
      else
        Apartment.connection
      end
    end

    # For short-lived operations that should release the connection right after
    # Uses with_connection in Rails 6+ or performs the operation with connection in older Rails
    def with_apartment_connection
      if block_given?
        if modern_connection_handling?
          Apartment.with_connection { |conn| yield(conn) }
        else
          yield(Apartment.connection)
        end
      else
        lease_apartment_connection
      end
    end

    # Explicitly release the connection - important after tenant switching
    # or at the end of requests to prevent connection leaks
    def release_apartment_connection
      if modern_connection_handling?
        Apartment.release_connection
      else
        Apartment.connection_class.connection_pool.release_connection
      end
    end
  end
end