# frozen_string_literal: true

require 'spec_helper'
require_relative 'support'
require 'apartment/test_fixtures'

# Integration coverage for the fixture pool lifecycle failure class.
#
# Design: docs/designs/fixture-pool-lifecycle.md (member #3).
#
# The invariant: pool lifecycle changes during fixture-transaction ownership
# are a violation. `reset_tenant_pools!` invoked mid-suite discards pools that
# Rails' transactional fixtures pinned for rollback; the next example's
# `setup_fixtures` snapshots `connection_pool_list` without them, and any
# lazy-recreated pool has fresh object identity that never enrolls in the
# fixture transaction.
#
# Five examples:
#   1. The guard raises `Apartment::FixtureLifecycleViolation` when a tenant
#      pool carries `@pinned_connection`.
#   2. The violation message names the offending tenant pool and redirects to
#      the truncation strategy (contract-locked text).
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
#      writes while teardown's rollback still misses them. Outcome determines
#      whether design member #6 (`preload_test_pools!`) ships.
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

  it 'violation message names the offending tenant pool and redirects to the truncation strategy doc' do
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
    expect(message).to(include('Apartment::Test::Truncation'))
    expect(message).to(include('docs/designs/fixture-pool-lifecycle.md'))
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
    # The (a′) question (design member #4, settles #6): `setup_fixtures` runs
    # first with no tenant pool, the example then switches to the tenant for
    # the first time and writes. Does the lazily-created pool enroll in the
    # fixture transaction so teardown rolls the row back?
    #
    # If GREEN: lazy enrollment works; `preload_test_pools!` is YAGNI.
    # If RED:   ship design member #6 to materialise pools pre-snapshot.
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
end
