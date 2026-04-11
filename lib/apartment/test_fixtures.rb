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
  # A guard ivar (@apartment_fixtures_cleaned) controls the two call paths:
  # first call runs cleanup + super; re-entrant calls (from the
  # !connection.active_record subscriber in setup_transactional_fixtures)
  # return immediately — apartment pools must not pass through super's
  # shard/role iteration.
  module TestFixtures
    private

    def setup_shared_connection_pool
      return if @apartment_fixtures_cleaned

      @apartment_fixtures_cleaned = true
      Apartment.reset_tenant_pools! if Apartment.pool_manager
      super
    end

    def teardown_shared_connection_pool
      @apartment_fixtures_cleaned = false
      super
    end
  end
end
