# frozen_string_literal: true

require 'spec_helper'

# This spec requires real ActiveRecord + sqlite3 gem (not the stub in apartment_spec.rb).
# Run via any sqlite3 appraisal, e.g.: bundle exec appraisal rails-8.1-sqlite3 rspec spec/unit/test_fixtures_spec.rb
# Skips gracefully when sqlite3 is not available or when the AR stub from
# apartment_spec.rb loaded first (randomized suite order).
REAL_AR_AVAILABLE_FOR_FIXTURES = begin
  require('active_record')
  # The stub in apartment_spec.rb defines AR::Base without establish_connection.
  # If that loaded first, real AR's require is a partial no-op. Detect this.
  if ActiveRecord::Base.respond_to?(:establish_connection)
    ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
    require_relative('../../lib/apartment/patches/connection_handling')
    ActiveRecord::Base.singleton_class.prepend(Apartment::Patches::ConnectionHandling)
    true
  else
    warn '[test_fixtures_spec] Skipping: AR stub loaded (no establish_connection)'
    false
  end
rescue LoadError => e
  warn "[test_fixtures_spec] Skipping: #{e.message}"
  false
end

# Ensure Apartment::TestFixtures is defined for the RSpec.describe block below.
# The real implementation is loaded inside 'with the patch' examples.
# When AR is unavailable, define a stub so the describe block doesn't raise NameError.
# When AR is available but the file hasn't been created yet, also define a stub.
unless defined?(Apartment::TestFixtures)
  module Apartment
    module TestFixtures; end
  end
end

# A host class that mimics what ActiveRecord::TestFixtures-including classes look like.
# Wraps setup_shared_connection_pool / teardown_shared_connection_pool as public methods
# so tests can call them directly without visibility friction.
if REAL_AR_AVAILABLE_FOR_FIXTURES
  class FixtureHost
    include ActiveRecord::TestFixtures if REAL_AR_AVAILABLE_FOR_FIXTURES

    # ActiveRecord::TestFixtures requires this ivar to be present.
    def initialize
      @saved_pool_configs = Hash.new { |hash, key| hash[key] = {} }
    end

    def call_setup
      setup_shared_connection_pool
    end

    def call_teardown
      teardown_shared_connection_pool
    end
  end
end

RSpec.describe(Apartment::TestFixtures) do
  before do
    skip 'requires real ActiveRecord with sqlite3 gem (run via appraisal)' unless REAL_AR_AVAILABLE_FOR_FIXTURES
    Apartment.configure do |config|
      config.tenant_strategy = :schema
      config.tenants_provider = -> { %w[acme] }
      config.default_tenant = 'public'
      config.check_pending_migrations = false
    end
    Apartment.adapter = mock_adapter
  end

  after do
    Apartment.clear_config
    Apartment::Current.reset
  end

  let(:mock_adapter) do
    double('AbstractAdapter',
           validated_connection_config: { 'adapter' => 'sqlite3', 'database' => ':memory:' },
           shared_pinned_connection?: false)
  end

  # Registers a tenant pool under a given role — simulates what ConnectionHandling#connection_pool does.
  def register_tenant_pool(tenant, role)
    prefix = Apartment.config.shard_key_prefix
    pool_key = "#{tenant}:#{role}"
    shard_key = :"#{prefix}_#{pool_key}"

    db_config = ActiveRecord::DatabaseConfigurations::HashConfig.new(
      Apartment.config.rails_env_name,
      "#{prefix}_#{pool_key}",
      { 'adapter' => 'sqlite3', 'database' => ':memory:' }
    )

    pool = ActiveRecord::Base.connection_handler.establish_connection(
      db_config,
      owner_name: ActiveRecord::Base,
      role: role,
      shard: shard_key
    )

    Apartment.pool_manager.fetch_or_create(pool_key) { pool }
  end

  describe 'without the patch' do
    it 'raises ArgumentError from setup_shared_connection_pool when a tenant pool exists under :reading only' do
      # Use a fresh anonymous host class to avoid contamination from the 'with the patch'
      # tests (prepend is irreversible on a class; FixtureHost may already be patched).
      fresh_host_class = Class.new do
        include ActiveRecord::TestFixtures

        def initialize
          @saved_pool_configs = Hash.new { |hash, key| hash[key] = {} }
        end

        def call_setup
          setup_shared_connection_pool
        end
      end

      register_tenant_pool('acme', :reading)
      host = fresh_host_class.new
      expect { host.call_setup }.to(raise_error(ArgumentError, /pool_config.*nil/i))
    end
  end

  describe 'with the patch' do
    before do
      require_relative('../../lib/apartment/test_fixtures')
      FixtureHost.prepend(described_class) unless FixtureHost <= described_class # rubocop:disable Style/YodaCondition
    end

    it 'does not raise when a tenant pool exists under :reading only' do
      register_tenant_pool('acme', :reading)
      host = FixtureHost.new
      expect { host.call_setup }.not_to(raise_error)
    end

    it 'clears apartment pools from the AR ConnectionHandler' do
      register_tenant_pool('acme', :reading)
      host = FixtureHost.new
      host.call_setup

      prefix = Apartment.config.shard_key_prefix
      registered = ActiveRecord::Base.connection_handler.retrieve_connection_pool(
        'ActiveRecord::Base',
        role: :reading,
        shard: :"#{prefix}_acme:reading"
      )
      expect(registered).to(be_nil)
    end

    it 'clears the pool manager' do
      register_tenant_pool('acme', :reading)
      host = FixtureHost.new
      host.call_setup

      expect(Apartment.pool_manager.stats[:total_pools]).to(eq(0))
    end

    it 'guard prevents cleanup on re-entrant calls' do
      register_tenant_pool('acme', :reading)
      host = FixtureHost.new

      # First call: guard trips, clears apartment pools, pool manager is empty
      host.call_setup
      expect(Apartment.pool_manager.stats[:total_pools]).to(eq(0))

      # Manually add a pool directly to pool_manager (bypassing AR handler)
      # to verify the second call does NOT clear it again.
      pool_key = 'acme:writing'
      Apartment.pool_manager.fetch_or_create(pool_key) { Object.new }

      # Second call: guard is set, cleanup block is skipped entirely
      host.call_setup

      expect(Apartment.pool_manager.stats[:total_pools]).to(eq(1))
    end

    it 'teardown_shared_connection_pool resets the guard' do
      host = FixtureHost.new
      host.call_setup
      expect(host.instance_variable_get(:@apartment_fixtures_cleaned)).to(be(true))

      host.call_teardown
      expect(host.instance_variable_get(:@apartment_fixtures_cleaned)).to(be(false))
    end
  end
end
