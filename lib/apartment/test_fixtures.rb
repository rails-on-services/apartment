# frozen_string_literal: true

module Apartment
  # Prepended on the class that includes ActiveRecord::TestFixtures
  # (e.g., ActiveSupport::TestCase or the RSpec fixture host).
  #
  # Rails' setup_shared_connection_pool iterates all shards registered in
  # the ConnectionHandler and assumes every shard has a :writing pool_config.
  # Apartment's role-specific tenant shards violate this invariant, causing
  # ArgumentError. This module deregisters apartment pools before the fixture
  # machinery iterates them. Pools rebuild lazily on next connection_pool call.
  #
  # A guard ivar (@apartment_fixtures_cleaned) prevents re-entry: the
  # !connection.active_record notification subscriber in
  # setup_transactional_fixtures calls setup_shared_connection_pool again
  # when new pools appear mid-example.
  module TestFixtures
    private

    def setup_shared_connection_pool
      unless @apartment_fixtures_cleaned
        @apartment_fixtures_cleaned = true
        if Apartment.pool_manager
          Apartment.send(:deregister_all_tenant_pools)
          Apartment.pool_manager.clear
          Apartment::Current.reset
        end
      end
      super
    end

    def teardown_shared_connection_pool
      @apartment_fixtures_cleaned = false
      super
    end
  end
end
