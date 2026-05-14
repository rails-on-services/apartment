# frozen_string_literal: true

require 'spec_helper'
require_relative 'support'
require 'apartment/test_fixtures'

# Regression guard for transactional-fixture visibility of lazily-created
# tenant pools.
#
# Apartment creates tenant pools lazily, on first access. Under a host
# application's transactional fixtures, that first access can land *after*
# Rails' `setup_transactional_fixtures` has snapshotted and pinned the
# :writing pools — so a lazy tenant pool is pinned late, by the
# `!connection.active_record` subscriber rather than the initial snapshot.
# The concern: a write made inside the example could miss the fixture
# transaction and be invisible to a later read on the same tenant.
#
# These specs drive the real Rails fixture lifecycle (`setup_fixtures` /
# `teardown_fixtures`, `Apartment::TestFixtures` prepended as the Railtie
# wires it) and confirm the subscriber pins the lazy pool in time:
# visibility holds across `with_tenants`, `each`, and nested `switch`. The
# last example also confirms PoolReaper can detect the pin — guarding the
# private-ivar read against a future ActiveRecord rename.
#
# :schema strategy is PG-only.
RSpec.describe('v4 transactional-fixture visibility for lazy tenant pools', :integration, # rubocop:disable RSpec/MultipleMemoizedHelpers
               skip: (V4_INTEGRATION_AVAILABLE && V4IntegrationHelper.postgresql? ? false : 'requires PostgreSQL')) do
  include V4IntegrationHelper

  # Drives the real Rails transactional-fixture lifecycle (the same
  # `setup_fixtures` / `teardown_fixtures` machinery rspec-rails invokes
  # around every example when `use_transactional_tests` is true).
  # `Apartment::TestFixtures` is prepended exactly as the v4 Railtie wires
  # it in a host application.
  if V4_INTEGRATION_AVAILABLE
    class FixtureLifecycleHost
      include ActiveRecord::TestFixtures
      prepend Apartment::TestFixtures

      def initialize
        @saved_pool_configs = Hash.new { |hash, key| hash[key] = {} }
      end

      # `ActiveRecord::TestFixtures#run_in_transaction?` expects a
      # Minitest-style host; supply the minimum it calls.
      def self.uses_transaction?(_name) = false
      def name = 'fixture_pin_visibility_reproduction'

      # Mirrors the rspec-rails example wrapper: setup -> body -> teardown.
      def run_example
        setup_fixtures
        yield
      ensure
        teardown_fixtures
      end
    end
  end

  let(:tmp_dir)      { Dir.mktmpdir('apartment_fixture_pin') }
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

    # Precondition: creating the tables above lazily registered tenant
    # pools. Clear them so the fixture lifecycle starts from the same
    # state a real suite does — tenant schemas exist, tenant pools do not.
    # `setup_transactional_fixtures` will then pin only `primary`, and the
    # first in-example write is what re-creates the tenant pool.
    Apartment.reset_tenant_pools!
  end

  after do
    ActiveRecord::Base.connection.execute('DROP SCHEMA IF EXISTS extensions CASCADE')
  ensure
    V4IntegrationHelper.cleanup_tenants!(tenants, Apartment.adapter)
    Apartment.clear_config
    Apartment::Current.reset
  end

  it 'sees rows written inside the example when a later pass re-enters the tenant' do
    widget_class
    counts = {}

    FixtureLifecycleHost.new.run_example do
      # Local `around { Apartment::Tenant.switch(write_tenant) }` wrapping a
      # `before(:each)` that writes: the first write lazily (re-)creates
      # `apartment_<write_tenant>:writing` mid-example.
      Apartment::Tenant.switch(write_tenant) do
        5.times { Widget.create! }

        # Example body: a job iterating every tenant and counting rows.
        Apartment::Tenant.each do |tenant|
          counts[tenant] = Widget.count
        end
      end
    end

    expect(counts[write_tenant]).to(eq(5))
  end

  # A `with_tenants` override wrapping the local switch — the shape of a
  # global tenant-scoping hook layered under a per-example
  # `around { switch }`.
  it 'sees in-example writes when a with_tenants override wraps the local switch' do
    widget_class
    counts = {}

    FixtureLifecycleHost.new.run_example do
      Apartment::Tenant.with_tenants(*tenants) do
        Apartment::Tenant.switch(write_tenant) do
          5.times { Widget.create! }

          Apartment::Tenant.each do |tenant|
            counts[tenant] = Widget.count
          end
        end
      end
    end

    expect(counts[write_tenant]).to(eq(5))
  end

  # The job iterates via `each` with no enclosing switch — `each` itself is
  # the only thing entering the write tenant, and it does so *after* the
  # `before(:each)` write already created+pinned the pool.
  it 'sees in-example writes when each re-enters the tenant from a with_tenants override' do
    widget_class
    counts = {}

    FixtureLifecycleHost.new.run_example do
      # `before(:each)` equivalent: write under a bare switch, then let it close.
      Apartment::Tenant.switch(write_tenant) { 5.times { Widget.create! } }

      # Example body: job iterates via the override list, no outer switch.
      Apartment::Tenant.with_tenants(*tenants) do
        Apartment::Tenant.each do |tenant|
          counts[tenant] = Widget.count
        end
      end
    end

    expect(counts[write_tenant]).to(eq(5))
  end

  # Triangulates PoolReaper#pool_pinned? against a real, freshly-pinned
  # ConnectionPool on whatever Rails version CI runs. The unit tests use a
  # bare-Object fake, so only this catches an ActiveRecord ivar rename.
  it 'pins the lazily-created tenant pool detectably for PoolReaper' do
    widget_class
    reaper = Apartment::PoolReaper.new(
      pool_manager: Apartment.pool_manager, interval: 60, idle_timeout: 60
    )
    pinned_mid_example = nil

    FixtureLifecycleHost.new.run_example do
      Apartment::Tenant.switch(write_tenant) do
        Widget.create!
        pool = Apartment.pool_manager.peek("#{write_tenant}:writing")
        pinned_mid_example = reaper.send(:pool_pinned?, pool)
      end
    end

    expect(pinned_mid_example).to(be(true))
  end
end
