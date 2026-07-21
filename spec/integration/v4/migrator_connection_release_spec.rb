# frozen_string_literal: true

require 'spec_helper'
require_relative 'support'
require 'apartment/migrator'

# Regression coverage for docs/designs/v4-migrator-per-tenant-connection-release.md:
# migrate_tenant must release the worker's leased connection so finished pools
# are no longer in_use? (and therefore admission-evictable).
#
#   bundle exec appraisal rails-8.1-sqlite3 rspec spec/integration/v4/migrator_connection_release_spec.rb
RSpec.describe('v4 Migrator connection release', :integration) do
  before(:all) do
    skip('requires ActiveRecord + database gem') unless V4_INTEGRATION_AVAILABLE
  end

  include V4IntegrationHelper

  let(:tmp_dir) { Dir.mktmpdir('apartment_migrator_release') }
  let(:migrations_dir) { File.join(tmp_dir, 'migrate') }
  let(:test_tenants) { %w[release_test_a release_test_b release_test_c] }
  let(:original_migrations_paths) { ActiveRecord::Migrator.migrations_paths.dup }

  def write_test_migration(dir)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, '20240101000001_create_release_test_widgets.rb'), <<~RUBY)
      # frozen_string_literal: true
      class CreateReleaseTestWidgets < ActiveRecord::Migration[7.0]
        def change
          create_table(:release_test_widgets, force: true) do |t|
            t.string :name
          end
        end
      end
    RUBY
  end

  # Peek the pool AR created for a tenant under the current role, without
  # touching its idle timestamp.
  def tenant_pool(tenant)
    Apartment.pool_manager.peek("#{tenant}:#{ActiveRecord::Base.current_role}")
  end

  def busy_connections(pool)
    pool.connections.count(&:in_use?)
  end

  def open_transactions(pool)
    pool.connections.sum { |c| c.respond_to?(:open_transactions) ? c.open_transactions : 0 }
  end

  before do
    write_test_migration(migrations_dir)
    ActiveRecord::Migrator.migrations_paths = [migrations_dir]

    V4IntegrationHelper.ensure_test_database! unless V4IntegrationHelper.sqlite?
    @connection_config = V4IntegrationHelper.establish_default_connection!(tmp_dir: tmp_dir)

    Apartment.configure do |c|
      c.tenant_strategy = V4IntegrationHelper.tenant_strategy
      c.tenants_provider = -> { test_tenants }
      c.default_tenant = V4IntegrationHelper.default_tenant
      c.check_pending_migrations = false
    end

    Apartment.adapter = V4IntegrationHelper.build_adapter(@connection_config)
    Apartment.activate!
    test_tenants.each { |t| Apartment.adapter.create(t) }
  end

  after do
    ActiveRecord::Migrator.migrations_paths = original_migrations_paths
    Apartment::Tenant.reset
    V4IntegrationHelper.cleanup_tenants!(test_tenants, Apartment.adapter)
    Apartment.clear_config
    Apartment::Current.reset
    if V4IntegrationHelper.sqlite?
      ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
      FileUtils.rm_rf(tmp_dir)
    end
  end

  it 'leaves no leased connection on any tenant pool after a successful run' do
    Apartment::Migrator.new(threads: 0).run

    test_tenants.each do |tenant|
      pool = tenant_pool(tenant)
      expect(pool).not_to(be_nil, "expected a pool for #{tenant}")
      expect(busy_connections(pool)).to(
        eq(0), "expected #{tenant} pool to have no leased connection after migrating"
      )
      expect(open_transactions(pool)).to(eq(0))
    end
  end

  it 'releases the connection even when a tenant migration raises' do
    # A second migration that raises ONLY for tenants, not the default (primary)
    # tenant. If it raised unconditionally, migrate_primary — which runs first —
    # would fail and Migrator#run would abort before touching any tenant, so the
    # per-tenant failure path (the thing under test) would never execute. Scoping
    # the raise lets the primary succeed and every tenant hit migrate_tenant's
    # rescue for real.
    File.write(File.join(migrations_dir, '20240101000002_boom.rb'), <<~RUBY)
      # frozen_string_literal: true
      class Boom < ActiveRecord::Migration[7.0]
        def change
          return if Apartment::Tenant.current.to_s == Apartment.config.default_tenant.to_s

          raise 'boom'
        end
      end
    RUBY

    run = Apartment::Migrator.new(threads: 0).run

    # Every tenant must have failed (proving the rescue path ran); the primary
    # must not be among the failures.
    expect(run.failed.map(&:tenant)).to(match_array(test_tenants))

    test_tenants.each do |tenant|
      pool = tenant_pool(tenant)
      # The pool exists because migrate_tenant captured it before Boom raised.
      expect(pool).not_to(be_nil, "expected a pool for #{tenant} after its failed migration")
      expect(busy_connections(pool)).to(eq(0), "expected #{tenant} pool released after a failed migration")
      expect(open_transactions(pool)).to(eq(0), "expected #{tenant} migration transaction rolled back")
    end
  end

  it 'releases cleanly on the skip path (already up to date)' do
    Apartment::Migrator.new(threads: 0).run # bring all tenants current
    second = Apartment::Migrator.new(threads: 0).run # everything :skipped now

    expect(second.results.reject { |r| r.tenant == Apartment.config.default_tenant })
      .to(all(have_attributes(status: :skipped)))

    test_tenants.each do |tenant|
      pool = tenant_pool(tenant)
      expect(busy_connections(pool)).to(eq(0)) if pool
    end
  end

  it 'targeted release does not disturb a connection the caller holds on another pool' do
    # Caller leases tenant A's pool on this thread; switch does not check it in,
    # so the lease persists after the block (that is the bug this fix addresses).
    Apartment::Tenant.switch(test_tenants[0]) do
      ActiveRecord::Base.connection.execute('SELECT 1')
    end
    pool_a = tenant_pool(test_tenants[0])
    expect(busy_connections(pool_a)).to(eq(1)) # caller's lease established

    # Migrate a DIFFERENT tenant; its targeted release touches only tenant B's pool.
    Apartment::Migrator.new(threads: 0).send(:migrate_tenant, test_tenants[1])

    expect(busy_connections(pool_a)).to(eq(1)) # caller's lease on A untouched
    expect(busy_connections(tenant_pool(test_tenants[1]))).to(eq(0)) # B released
  end

  describe 'under a pool cap (admission)' do
    # default pool (protected) + cap of 2 tenant pools, migrating 3 tenants,
    # forces at least one admission eviction. With the connection released after
    # each tenant, the LRU tenant pool is not in_use? and evicts cleanly, so no
    # :cap_unmet fires. Without release it would (the production incident).
    before do
      Apartment.configure do |c|
        c.tenant_strategy = V4IntegrationHelper.tenant_strategy
        c.tenants_provider = -> { test_tenants }
        c.default_tenant = V4IntegrationHelper.default_tenant
        c.check_pending_migrations = false
        c.max_tenant_pools = 2
      end
      # configure tears down @adapter (see lib/apartment.rb#teardown_old_state);
      # re-set it before activate!, same as the outer before, so the lazy
      # Apartment.adapter accessor doesn't recurse through
      # ConnectionHandling#connection_pool -> build_adapter -> Apartment.adapter.
      Apartment.adapter = V4IntegrationHelper.build_adapter(@connection_config)
      Apartment.activate!
    end

    it 'does not emit :cap_unmet and keeps registered pools within the cap' do
      cap_unmet = []
      sub = ActiveSupport::Notifications.subscribe('cap_unmet.apartment') do |*args|
        cap_unmet << args.last
      end

      run = Apartment::Migrator.new(threads: 0).run
      # Guard against a vacuous pass: if the run failed before creating pools,
      # cap_unmet and the pool count would both be empty for the wrong reason.
      expect(run).to(be_success)

      # Count only the test-tenant pools (keys "<tenant>:<role>"), excluding the
      # protected default pool and any reading-role pool, so the bound is robust.
      tenant_pool_count = Apartment.pool_manager.stats[:tenants].count do |key|
        test_tenants.any? { |t| key.to_s.start_with?("#{t}:") }
      end
      expect(cap_unmet).to(be_empty)
      expect(tenant_pool_count).to(be <= 2)
    ensure
      ActiveSupport::Notifications.unsubscribe(sub)
    end

    # The production incident was a PARALLEL migrate under a cap. This is that
    # shape: concurrent workers each releasing their own tenant's lease, so
    # admission can evict released pools instead of hitting the skip_evict/
    # cap_unmet wall. It also exercises the capture->lease eviction window — if a
    # worker's captured pool could be evicted before its sticky lease, a leased
    # replacement pool would survive and cap_unmet would fire.
    it 'stays within the cap under parallel workers without a cap_unmet storm',
       skip: (V4IntegrationHelper.sqlite? ? 'SQLite does not support concurrent connections' : false) do
      cap_unmet = []
      sub = ActiveSupport::Notifications.subscribe('cap_unmet.apartment') do |*args|
        cap_unmet << args.last
      end

      run = Apartment::Migrator.new(threads: 2).run
      expect(run).to(be_success)
      expect(cap_unmet).to(be_empty)

      # No finished tenant pool still holds a lease after all workers joined.
      Apartment.pool_manager.stats[:tenants].each do |key|
        next unless test_tenants.any? { |t| key.to_s.start_with?("#{t}:") }

        pool = Apartment.pool_manager.peek(key)
        expect(busy_connections(pool)).to(eq(0), "expected #{key} released after parallel migrate") if pool
      end
    ensure
      ActiveSupport::Notifications.unsubscribe(sub)
    end
  end
end
