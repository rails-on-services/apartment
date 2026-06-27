# frozen_string_literal: true

require 'spec_helper'
require_relative 'support'
require 'apartment/test_fixtures'

# Integration coverage for the fixture pool lifecycle failure class.
#
# Design: docs/designs/fixture-pool-lifecycle.md (failure-class members 3 and 4).
#
# The invariant: pool lifecycle changes during fixture-transaction ownership
# are a violation. `reset_tenant_pools!` invoked mid-suite discards pools that
# Rails' transactional fixtures pinned for rollback; the next example's
# `setup_fixtures` snapshots `connection_pool_list` without them, and any
# lazy-recreated pool has fresh object identity that never enrolls in the
# fixture transaction.
#
# Six examples:
#   1. The guard raises `Apartment::FixtureLifecycleViolation` when a tenant
#      pool carries `@pinned_connection`.
#   2. The violation message names the offending tenant pool and points at the
#      use_transactional_tests = false opt-out and docs/testing.md (contract-locked text).
#   3. Negative case: with no pinned pools, the call passes (the guard must
#      not over-trigger and break suite bootstrapping — `Apartment::TestFixtures`
#      itself invokes `reset_tenant_pools!` before `setup_shared_connection_pool`
#      pins primary).
#   4. Mechanism documentation: with the test-env guard bypassed, mid-tx
#      reset discards the pinned pool and the recreated pool has a fresh
#      object identity. Asserts pool object identity (not tenant name) — the
#      thing fixtures actually enroll for rollback.
#   5. The (a′) tiebreaker: does a tenant pool created lazily inside an
#      example (no prior reset) enroll in the fixture rollback? Asserts
#      rollback, not visibility — a leased connection can pass in-example
#      writes while teardown's rollback still misses them. Settled green
#      across the matrix; the `preload_test_pools!` helper was retired
#      unbuilt. This example stays as the regression lock.
#   6. reset_tenant_pools! resets pools only — it must not clear
#      Apartment::Current. Drives the real around-hook -> setup_fixtures ->
#      setup_shared_connection_pool -> reset_tenant_pools! chain and asserts
#      a with_tenants override survives it.
#
# Examples 1-6 run under the default :writing role. A ':reading role' context
# plus a both-roles example add the multi-handler variant (failure-class
# member 5, role axis): a per-tenant :reading pool, materialized by a READ
# (Rails forbids writes through :reading), pins / trips the guard / rebuilds
# with fresh identity per handler, and coexists with the :writing pool as a
# distinct, independently-pinned object. See those examples' comments for the
# read-visibility gap that is explicitly out of scope.
#
# Covers Rails 7.2 / 8.0 / 8.1 via the existing appraisal matrix.
# :schema strategy is PG-only; `pin_connection!` semantics are crispest there.
RSpec.describe('v4 fixture pool lifecycle guards', :integration, # rubocop:disable RSpec/MultipleMemoizedHelpers
               skip: (V4_INTEGRATION_AVAILABLE && V4IntegrationHelper.postgresql? ? false : 'requires PostgreSQL')) do
  include V4IntegrationHelper

  # Drives the real Rails transactional-fixture lifecycle (the same
  # `setup_fixtures` / `teardown_fixtures` machinery rspec-rails invokes
  # around every example when `use_transactional_tests` is true).
  # `Apartment::TestFixtures` is prepended exactly as the v4 Railtie wires it
  # in a host application.
  if V4_INTEGRATION_AVAILABLE
    class FixtureLifecycleGuardHost
      include ActiveRecord::TestFixtures
      prepend Apartment::TestFixtures

      def initialize
        @saved_pool_configs = Hash.new { |hash, key| hash[key] = {} }
      end

      # `false` keeps transactional fixtures (and the pinning subscriber) ON.
      def self.uses_transaction?(_name) = false
      def name = 'fixture_pool_lifecycle_host'

      # Mirrors the rspec-rails example wrapper: setup -> body -> teardown.
      def run_example
        setup_fixtures
        yield
      ensure
        teardown_fixtures
      end
    end
  end

  let(:tmp_dir)      { Dir.mktmpdir('apartment_fixture_lifecycle') }
  let(:rand_suffix)  { SecureRandom.hex(4) }
  let(:tenants)      { ["acme_#{rand_suffix}", "globex_#{rand_suffix}"] }
  let(:write_tenant) { tenants.first }
  let(:table_name)   { "widgets_#{rand_suffix}" }
  let(:widget_class) do
    klass = Class.new(ActiveRecord::Base)
    klass.table_name = table_name
    stub_const('Widget', klass)
    klass
  end

  before do
    V4IntegrationHelper.ensure_test_database!
    config = V4IntegrationHelper.establish_default_connection!(tmp_dir: tmp_dir)
    # Register a :reading default pool (same physical DB) so the :reading-role
    # context below can materialize per-tenant :reading pools.
    V4IntegrationHelper.register_reading_role!(config)
    ActiveRecord::Base.connection.execute('CREATE SCHEMA IF NOT EXISTS extensions')

    Apartment.configure do |c|
      c.tenant_strategy   = :schema
      c.tenants_provider  = -> { tenants }
      c.default_tenant    = 'public'
      c.check_pending_migrations = false
      c.configure_postgres { |pg| pg.persistent_schemas = ['extensions'] }
    end
    Apartment.adapter = V4IntegrationHelper.build_adapter(config)
    Apartment.activate!

    tenants.each do |name|
      Apartment.adapter.create(name)
      Apartment::Tenant.switch(name) do
        V4IntegrationHelper.create_test_table!(table_name)
      end
    end

    # Bring each example to the baseline a real suite starts from: tenant
    # schemas exist, tenant pools do not. `setup_shared_connection_pool` will
    # then pin only `primary`; the first in-example switch is what
    # lazily (re-)creates a tenant pool.
    Apartment.reset_tenant_pools!
  end

  after do
    ActiveRecord::Base.connection.execute('DROP SCHEMA IF EXISTS extensions CASCADE')
  ensure
    V4IntegrationHelper.cleanup_tenants!(tenants, Apartment.adapter)
    Apartment.clear_config
    Apartment::Current.reset
  end

  it 'raises Apartment::FixtureLifecycleViolation when a tenant pool is pinned by fixtures' do
    widget_class

    expect do
      FixtureLifecycleGuardHost.new.run_example do
        Apartment::Tenant.switch(write_tenant) { Widget.create! }
        expect(Apartment.pool_manager.peek("#{write_tenant}:writing")).not_to(be_nil)

        Apartment.reset_tenant_pools!
      end
    end.to(raise_error(Apartment::FixtureLifecycleViolation))
  end

  it 'violation message names the offending tenant pool and points at the use_transactional_tests opt-out' do
    widget_class

    message = nil
    begin
      FixtureLifecycleGuardHost.new.run_example do
        Apartment::Tenant.switch(write_tenant) { Widget.create! }
        Apartment.reset_tenant_pools!
      end
    rescue Apartment::FixtureLifecycleViolation => e
      message = e.message
    end

    expect(message).not_to(be_nil)
    expect(message).to(include("#{write_tenant}:writing"))
    expect(message).to(include('transactional fixtures'))
    expect(message).to(include('use_transactional_tests = false'))
    expect(message).to(include('docs/testing.md'))
  end

  it 'is allowed outside fixture-transaction ownership (negative case)' do
    # No pool carries `@pinned_connection` here. The guard must let the call
    # through; over-broad guarding would break suite bootstrap (Apartment's
    # own `TestFixtures` patch invokes `reset_tenant_pools!` *before*
    # `setup_shared_connection_pool` pins primary).
    widget_class
    Apartment::Tenant.switch(write_tenant) { Widget.create! }
    expect(Apartment.pool_manager.peek("#{write_tenant}:writing")).not_to(be_nil)

    expect { Apartment.reset_tenant_pools! }.not_to(raise_error)
    expect(Apartment.pool_manager.peek("#{write_tenant}:writing")).to(be_nil)
  end

  it 'mid-tx reset discards the pinned pool: the recreated pool has fresh object identity' do
    # The mechanism the guard prevents. With the test-env guard bypassed
    # (`Rails.env.test?` → false), reset proceeds and the rebuilt pool's
    # `object_id` differs from the one fixtures pinned — pool identity, not
    # tenant name, is what fixture rollback enrols.
    widget_class

    FixtureLifecycleGuardHost.new.run_example do
      Apartment::Tenant.switch(write_tenant) { Widget.create! }
      pool_before = Apartment.pool_manager.peek("#{write_tenant}:writing")

      # Simulate the production path the guard does not enforce.
      allow(Rails).to(receive(:env).and_return(ActiveSupport::StringInquirer.new('development')))
      Apartment.reset_tenant_pools!

      Apartment::Tenant.switch(write_tenant) { Widget.create! }
      pool_after = Apartment.pool_manager.peek("#{write_tenant}:writing")

      expect(pool_after).not_to(be(pool_before))
      expect(pool_after.object_id).not_to(eq(pool_before.object_id))
    end
  end

  it 'rolls back rows written via lazy pool creation in the non-reset path (a′ tiebreaker)' do
    # The (a′) question (failure-class member 4): `setup_fixtures` runs
    # first with no tenant pool, the example then switches to the tenant for
    # the first time and writes. Does the lazily-created pool enroll in the
    # fixture transaction so teardown rolls the row back?
    #
    # Settled green across the matrix: lazy enrollment works, so the
    # `preload_test_pools!` helper was retired unbuilt (see the design doc's
    # Never list). This example stays as the regression lock.
    #
    # Asserting rollback (not visibility): a leased connection can return
    # in-example writes via the same handle while teardown's enrollment
    # walk still misses the pool — fixture_pin_visibility_spec covers
    # visibility; rollback is the untested half.
    widget_class

    FixtureLifecycleGuardHost.new.run_example do
      Apartment::Tenant.switch(write_tenant) { Widget.create! }
    end

    post_rollback_count = nil
    Apartment::Tenant.switch(write_tenant) { post_rollback_count = Widget.count }

    expect(post_rollback_count).to(eq(0))
  end

  it 'preserves a with_tenants override across fixture setup (reset_tenant_pools! leaves Current intact)' do
    # The downstream failure path, end to end: an outer scope sets
    # tenant_override, then setup_fixtures runs reset_tenant_pools! via
    # setup_shared_connection_pool. reset_tenant_pools! must not clear
    # Apartment::Current — pool lifecycle and tenant context are separate.
    # The unit specs lock the method in isolation; this locks the real
    # fixture-setup chain (around-hook -> setup_fixtures -> reset).
    widget_class
    observed_override = nil
    observed_names    = nil

    Apartment::Tenant.with_tenants(write_tenant) do
      FixtureLifecycleGuardHost.new.run_example do
        observed_override = Apartment::Current.tenant_override
        observed_names    = Apartment.tenant_names
      end
    end

    # tenants_provider returns the full `tenants` list; the override is the
    # single write_tenant. A wiped override falls back to the provider, so
    # the one-element result distinguishes survived-override from fallback.
    expect(observed_override).to(eq([write_tenant]))
    expect(observed_names).to(eq([write_tenant]))
  end

  # The multi-handler / :reading variant (failure-class member 5, role axis).
  #
  # Rails makes the :reading role read-only (connection_handling.rb forces
  # prevent_writes for ActiveRecord.reading_role), and apps never write through
  # it — so these examples MATERIALIZE the per-tenant :reading pool with a READ,
  # then exercise the same lifecycle invariant the :writing examples above do.
  # What this proves: AR snapshots only connection_pool_list(:writing) at fixture
  # setup, so a :reading tenant pool enrolls solely via the lazy
  # !connection.active_record subscriber — these examples confirm it pins,
  # trips the guard, and rebuilds with fresh identity, per handler.
  #
  # NOT covered here (by design): rollback/visibility of writes made *through*
  # the :reading role. Writes can't happen under :reading, and a :reading tenant
  # pool does not see the :writing pool's uncommitted fixture writes (distinct
  # connections, never connection-shared for tenant shards) — tracked as a
  # separate failure-class member in docs/designs/fixture-pool-lifecycle.md.
  context 'under the :reading role' do # rubocop:disable RSpec/MultipleMemoizedHelpers
    it 'raises Apartment::FixtureLifecycleViolation when a :reading tenant pool is pinned' do
      widget_class

      expect do
        FixtureLifecycleGuardHost.new.run_example do
          ActiveRecord::Base.connected_to(role: :reading) do
            # A read materializes the pool; the subscriber pins it.
            Apartment::Tenant.switch(write_tenant) { Widget.count }
            reading_pool = Apartment.pool_manager.peek("#{write_tenant}:reading")
            expect(reading_pool).not_to(be_nil)
            # Prove it is actually enrolled (pinned), not merely created — the
            # guard fires on @pinned_connection, the same primitive asserted here.
            expect(Apartment::PoolReaper.pool_pinned?(reading_pool)).to(be(true))

            Apartment.reset_tenant_pools!
          end
        end
      end.to(raise_error(Apartment::FixtureLifecycleViolation))
    end

    it 'violation message names the offending :reading tenant pool' do
      widget_class

      message = nil
      begin
        FixtureLifecycleGuardHost.new.run_example do
          ActiveRecord::Base.connected_to(role: :reading) do
            Apartment::Tenant.switch(write_tenant) { Widget.count }
            Apartment.reset_tenant_pools!
          end
        end
      rescue Apartment::FixtureLifecycleViolation => e
        message = e.message
      end

      expect(message).not_to(be_nil)
      expect(message).to(include("#{write_tenant}:reading"))
      expect(message).to(include('use_transactional_tests = false'))
    end

    it 'mid-tx reset discards the pinned :reading pool: the recreated pool has fresh object identity' do
      widget_class

      FixtureLifecycleGuardHost.new.run_example do
        ActiveRecord::Base.connected_to(role: :reading) do
          Apartment::Tenant.switch(write_tenant) { Widget.count }
          pool_before = Apartment.pool_manager.peek("#{write_tenant}:reading")

          allow(Rails).to(receive(:env).and_return(ActiveSupport::StringInquirer.new('development')))
          Apartment.reset_tenant_pools!

          Apartment::Tenant.switch(write_tenant) { Widget.count }
          pool_after = Apartment.pool_manager.peek("#{write_tenant}:reading")

          expect(pool_after).not_to(be(pool_before))
          expect(pool_after.object_id).not_to(eq(pool_before.object_id))
        end
      end
    end
  end

  it 'pins :writing and :reading tenant pools as distinct, independently-pinned objects per handler' do
    # The per-handler proof (failure-class member 5, role axis): write under
    # :writing, read under :reading (the only direction Rails allows), and
    # confirm both materialize as DISTINCT pool objects that are each pinned
    # by the fixture lifecycle. Same physical DB, so the load-bearing evidence
    # is pool identity + pinning, not row counts (panel review flagged a
    # count-only assertion as degenerate here). The :writing rows still roll
    # back at teardown as a secondary sanity check.
    widget_class

    FixtureLifecycleGuardHost.new.run_example do
      ActiveRecord::Base.connected_to(role: :writing) do
        Apartment::Tenant.switch(write_tenant) { Widget.create! }
      end
      ActiveRecord::Base.connected_to(role: :reading) do
        Apartment::Tenant.switch(write_tenant) { Widget.count }
      end

      writing_pool = Apartment.pool_manager.peek("#{write_tenant}:writing")
      reading_pool = Apartment.pool_manager.peek("#{write_tenant}:reading")

      expect(writing_pool).not_to(be_nil)
      expect(reading_pool).not_to(be_nil)
      expect(reading_pool).not_to(be(writing_pool))

      expect(Apartment::PoolReaper.pool_pinned?(writing_pool)).to(be(true))
      expect(Apartment::PoolReaper.pool_pinned?(reading_pool)).to(be(true))
    end

    post_rollback_count = nil
    Apartment::Tenant.switch(write_tenant) { post_rollback_count = Widget.count }
    expect(post_rollback_count).to(eq(0))
  end
end
