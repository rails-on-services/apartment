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

  # Documents AR's baseline behavior: setup_shared_connection_pool raises
  # ArgumentError when a tenant pool exists under :reading without :writing.
  # That bug is why Apartment::TestFixtures exists; this group is a
  # regression guard against Rails fixing it (in which case the patch can
  # be retired). The describe wording deliberately avoids "without the
  # patch" -- under #412 the Railtie is now loaded in CI, the
  # `:active_record_fixtures` on_load callback fires for every class that
  # includes AR::TestFixtures (FixtureHost may already be prepended in
  # full-suite order), and a fresh anonymous host can no longer dodge the
  # prepend. The example below intentionally bypasses the prepend chain
  # via UnboundMethod#bind_call to invoke AR's own definition directly.
  describe 'AR baseline (unpatched method, invoked via bind_call)' do
    it 'AR setup_shared_connection_pool raises ArgumentError when a tenant pool exists under :reading only' do
      ar_setup = ActiveRecord::TestFixtures.instance_method(:setup_shared_connection_pool)

      # Robustness guard: bind_call bypasses prepend ONLY when the prepend
      # lands on the including class (per-class), not on AR::TestFixtures
      # itself. The current design (ActiveSupport::Concern's `included do`
      # block fires the on_load hook with `self == including class`) keeps
      # the prepend per-class. If a future Rails or Apartment change shifts
      # the prepend onto AR::TestFixtures itself, instance_method would
      # return the prepended version and this test would silently test the
      # wrong thing. The owner check fails loudly in that scenario.
      expect(ar_setup.owner).to(eq(ActiveRecord::TestFixtures))

      host = FixtureHost.new
      register_tenant_pool('acme', :reading)
      expect { ar_setup.bind_call(host) }.to(raise_error(ArgumentError, /pool_config.*nil/i))
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

    # Simulates Trigger B: the !connection.active_record subscriber re-entry.
    #
    # In production, the sequence is:
    # 1. First setup_shared_connection_pool call cleans up + runs super (OK)
    # 2. setup_transactional_fixtures subscribes to !connection.active_record
    # 3. Test runs, elevator creates tenant pool via establish_connection
    # 4. Subscriber fires synchronously (pool_config already in Rails' PoolManager)
    # 5. Subscriber calls setup_shared_connection_pool again
    # 6. Guard must skip both cleanup AND super — super would crash on the
    #    apartment shard that has no :writing pool_config
    #
    # We approximate step 3-6 by registering a pool in both the ConnectionHandler
    # and apartment's pool_manager after the first call, then verifying the second
    # call returns early without raising.
    it 'guard skips both cleanup and super on re-entrant calls (Trigger B)' do
      host = FixtureHost.new

      # First call: no apartment pools, clean pass-through
      host.call_setup
      expect(Apartment.pool_manager.stats[:total_pools]).to(eq(0))

      # Simulate elevator creating a tenant pool mid-test (registered in both
      # the AR ConnectionHandler and apartment's pool_manager, just like
      # ConnectionHandling#connection_pool does).
      register_tenant_pool('acme', :reading)

      # Second call: guard is set, returns early without calling super.
      # Without the fix, super would iterate shard_names, find
      # :apartment_acme:reading with no :writing pool_config, and raise
      # ArgumentError from PoolManager#set_pool_config.
      expect { host.call_setup }.not_to(raise_error)

      # Pool survives — guard prevented both cleanup and super
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
