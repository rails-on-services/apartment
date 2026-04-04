# frozen_string_literal: true

require 'spec_helper'
require_relative '../../lib/apartment/migrator'

RSpec.describe(Apartment::Migrator::Result) do
  subject(:result) do
    described_class.new(
      tenant: 'acme',
      status: :success,
      duration: 1.23,
      error: nil,
      versions_run: [20_260_401_000_000, 20_260_402_000_000]
    )
  end

  it 'is frozen (Data.define)' do
    expect(result).to(be_frozen)
  end

  it 'exposes all attributes' do
    expect(result.tenant).to(eq('acme'))
    expect(result.status).to(eq(:success))
    expect(result.duration).to(eq(1.23))
    expect(result.error).to(be_nil)
    expect(result.versions_run).to(eq([20_260_401_000_000, 20_260_402_000_000]))
  end
end

RSpec.describe(Apartment::Migrator::MigrationRun) do
  let(:success_result) do
    Apartment::Migrator::Result.new(
      tenant: 'acme', status: :success, duration: 1.0, error: nil, versions_run: [1]
    )
  end
  let(:failed_result) do
    Apartment::Migrator::Result.new(
      tenant: 'broken', status: :failed, duration: 0.5,
      error: StandardError.new('boom'), versions_run: []
    )
  end
  let(:skipped_result) do
    Apartment::Migrator::Result.new(
      tenant: 'current', status: :skipped, duration: 0.01, error: nil, versions_run: []
    )
  end

  describe 'with mixed results' do
    subject(:run) do
      described_class.new(
        results: [success_result, failed_result, skipped_result],
        total_duration: 2.5,
        threads: 4
      )
    end

    describe '#succeeded' do
      it 'returns only success results' do
        expect(run.succeeded.map(&:tenant)).to(eq(['acme']))
      end
    end

    describe '#failed' do
      it 'returns only failed results' do
        expect(run.failed.map(&:tenant)).to(eq(['broken']))
      end
    end

    describe '#skipped' do
      it 'returns only skipped results' do
        expect(run.skipped.map(&:tenant)).to(eq(['current']))
      end
    end

    describe '#success?' do
      it 'returns false when there are failures' do
        expect(run.success?).to(be(false))
      end
    end

    describe '#summary' do
      it 'includes counts, timing, and error details' do
        summary = run.summary
        expect(summary).to(include('3 tenants'))
        expect(summary).to(include('2.5s'))
        expect(summary).to(include('1 succeeded'))
        expect(summary).to(include('1 failed'))
        expect(summary).to(include('1 skipped'))
        expect(summary).to(include('broken'))
        expect(summary).to(include('StandardError'))
        expect(summary).to(include('boom'))
      end
    end
  end

  describe 'with all success' do
    subject(:run) do
      described_class.new(
        results: [success_result, skipped_result],
        total_duration: 1.0,
        threads: 2
      )
    end

    it '#success? returns true' do
      expect(run.success?).to(be(true))
    end

    it '#summary omits failed section' do
      summary = run.summary
      expect(summary).to(include('2 tenants'))
      expect(summary).to(include('1 succeeded'))
      expect(summary).to(include('1 skipped'))
      expect(summary).not_to(include('failed'))
    end
  end
end

RSpec.describe(Apartment::Migrator) do
  before do
    Apartment.configure do |c|
      c.tenant_strategy = :schema
      c.tenants_provider = -> { %w[acme beta] }
      c.default_tenant = 'public'
    end
  end

  describe '#initialize' do
    it 'defaults to 0 threads and nil version' do
      migrator = described_class.new
      expect(migrator.instance_variable_get(:@threads)).to(eq(0))
      expect(migrator.instance_variable_get(:@version)).to(be_nil)
    end

    it 'accepts threads and version parameters' do
      migrator = described_class.new(threads: 8, version: 20_260_401_000_000)
      expect(migrator.instance_variable_get(:@threads)).to(eq(8))
      expect(migrator.instance_variable_get(:@version)).to(eq(20_260_401_000_000))
    end
  end

  describe '#run' do
    let(:migrator) { described_class.new(threads: 0) }
    let(:mock_migration_context) { instance_double('ActiveRecord::MigrationContext') }
    let(:mock_pool) { instance_double('ActiveRecord::ConnectionAdapters::ConnectionPool') }
    let(:mock_connection) { double('connection') }

    before do
      allow(ActiveRecord::Base).to(receive_messages(connection_pool: mock_pool, lease_connection: mock_connection))
      allow(mock_connection).to(receive(:instance_variable_get).and_return(true))
      allow(mock_connection).to(receive(:instance_variable_set))
      allow(mock_pool).to(receive(:migration_context).and_return(mock_migration_context))
      allow(mock_migration_context).to(receive_messages(needs_migration?: true, migrate: []))
      allow(Apartment::Instrumentation).to(receive(:instrument))
      allow(Apartment::Tenant).to(receive(:switch)) { |_tenant, &block| block.call }
    end

    it 'returns a MigrationRun' do
      result = migrator.run
      expect(result).to(be_a(Apartment::Migrator::MigrationRun))
    end

    it 'includes primary and tenant results' do
      result = migrator.run
      tenants = result.results.map(&:tenant)
      expect(tenants).to(include('public'))
      expect(tenants).to(include('acme'))
      expect(tenants).to(include('beta'))
    end

    it 'primary result comes first' do
      result = migrator.run
      expect(result.results.first.tenant).to(eq('public'))
    end

    it 'returns :skipped for tenants with no pending migrations' do
      allow(mock_migration_context).to(receive(:needs_migration?).and_return(false))
      result = migrator.run
      expect(result.results.map(&:status)).to(all(eq(:skipped)))
    end

    it 'captures errors without halting the run when a tenant fails' do
      call_count = 0
      allow(mock_migration_context).to(receive(:migrate)) do
        call_count += 1
        raise(StandardError, 'boom') if call_count == 2

        []
      end
      result = migrator.run
      expect(result.failed.size).to(be >= 1)
      expect(result.results.size).to(eq(3))
    end

    it 'aborts and returns only the primary result when primary migration fails' do
      allow(mock_migration_context).to(receive(:migrate).and_raise(StandardError, 'db down'))
      result = migrator.run
      expect(result.results.size).to(eq(1))
      expect(result.results.first.status).to(eq(:failed))
      expect(result).not_to(be_success)
    end

    it 'instruments each migration' do
      expect(Apartment::Instrumentation).to(receive(:instrument)
        .with(:migrate_tenant, hash_including(:tenant)).at_least(3).times)
      migrator.run
    end

    it 'switches tenant for each tenant migration' do
      migrator.run
      expect(Apartment::Tenant).to(have_received(:switch).with('acme'))
      expect(Apartment::Tenant).to(have_received(:switch).with('beta'))
    end

    it 'disables advisory locks for tenant migrations and restores afterward' do
      migrator.run
      expect(mock_connection).to(have_received(:instance_variable_set)
        .with(:@advisory_locks_enabled, false).at_least(:twice))
      expect(mock_connection).to(have_received(:instance_variable_set)
        .with(:@advisory_locks_enabled, true).at_least(:twice))
    end

    it 'handles empty tenant list' do
      Apartment.configure do |c|
        c.tenant_strategy = :schema
        c.tenants_provider = -> { [] }
        c.default_tenant = 'public'
      end
      result = migrator.run
      expect(result.results.size).to(eq(1))
    end

    context 'with target version' do
      let(:migrator) { described_class.new(threads: 0, version: 20_260_401_000_000) }

      it 'passes version to migrate' do
        expect(mock_migration_context).to(receive(:migrate).with(20_260_401_000_000).at_least(:once).and_return([]))
        migrator.run
      end

      it 'does not skip based on needs_migration? when version is set' do
        allow(mock_migration_context).to(receive(:needs_migration?).and_return(false))
        result = migrator.run
        # With a version target, migrate is called even if needs_migration? is false
        # (could be a rollback to an older version)
        expect(result.results.map(&:status)).to(all(eq(:success)))
      end
    end
  end

  describe '#migrate_tenant Current.migrating lifecycle' do
    let(:mock_pool) { double('pool', migration_context: double(needs_migration?: false)) }

    it 'sets Current.migrating = true before Tenant.switch' do
      migrating_value_during_switch = nil
      allow(Apartment::Tenant).to(receive(:switch)) do |&block|
        migrating_value_during_switch = Apartment::Current.migrating
        block&.call
      end
      allow(ActiveRecord::Base).to(receive(:connection_pool).and_return(mock_pool))

      migrator = described_class.new
      migrator.send(:migrate_tenant, 'acme')

      expect(migrating_value_during_switch).to(be(true))
    end

    it 'clears Current.migrating after migrate_tenant completes' do
      allow(Apartment::Tenant).to(receive(:switch).and_yield)
      allow(ActiveRecord::Base).to(receive(:connection_pool).and_return(mock_pool))

      migrator = described_class.new
      migrator.send(:migrate_tenant, 'acme')

      expect(Apartment::Current.migrating).to(be_falsey)
    end

    it 'clears Current.migrating even on error' do
      allow(Apartment::Tenant).to(receive(:switch).and_raise(StandardError, 'boom'))

      migrator = described_class.new
      migrator.send(:migrate_tenant, 'acme')

      expect(Apartment::Current.migrating).to(be_falsey)
    end
  end

  describe '#with_migration_role' do
    it 'yields without connected_to when migration_role is nil' do
      migrator = described_class.new
      expect(ActiveRecord::Base).not_to(receive(:connected_to))
      migrator.send(:with_migration_role) { 'result' }
    end

    it 'wraps in connected_to when migration_role is set' do
      Apartment.configure do |c|
        c.tenant_strategy = :schema
        c.tenants_provider = -> { [] }
        c.default_tenant = 'public'
        c.migration_role = :db_manager
      end
      migrator = described_class.new
      expect(ActiveRecord::Base).to(receive(:connected_to).with(role: :db_manager).and_yield)
      migrator.send(:with_migration_role) { 'result' }
    end
  end

  describe '#evict_migration_pools' do
    it 'evicts pools by migration_role and deregisters shards' do
      Apartment.configure do |c|
        c.tenant_strategy = :schema
        c.tenants_provider = -> { [] }
        c.default_tenant = 'public'
        c.migration_role = :db_manager
      end
      pool_manager = instance_double(Apartment::PoolManager)
      allow(Apartment).to(receive(:pool_manager).and_return(pool_manager))
      allow(pool_manager).to(receive(:evict_by_role).with(:db_manager).and_return([['acme:db_manager', double]]))
      allow(Apartment).to(receive(:deregister_shard))

      migrator = described_class.new
      migrator.send(:evict_migration_pools)

      expect(pool_manager).to(have_received(:evict_by_role).with(:db_manager))
      expect(Apartment).to(have_received(:deregister_shard).with('acme:db_manager'))
    end

    it 'no-ops when migration_role is nil' do
      migrator = described_class.new
      expect(Apartment).not_to(receive(:pool_manager))
      migrator.send(:evict_migration_pools)
    end
  end

  describe '#migrate_one' do
    let(:migrator) { described_class.new }
    let(:mock_migration_context) { instance_double('ActiveRecord::MigrationContext') }
    let(:mock_pool) { instance_double('ActiveRecord::ConnectionAdapters::ConnectionPool') }
    let(:mock_connection) { double('connection') }

    before do
      allow(ActiveRecord::Base).to(receive_messages(connection_pool: mock_pool, lease_connection: mock_connection))
      allow(mock_connection).to(receive(:instance_variable_get).and_return(true))
      allow(mock_connection).to(receive(:instance_variable_set))
      allow(mock_pool).to(receive(:migration_context).and_return(mock_migration_context))
      allow(mock_migration_context).to(receive_messages(needs_migration?: true, migrate: []))
      allow(Apartment::Instrumentation).to(receive(:instrument))
      allow(Apartment::Tenant).to(receive(:switch)) { |_tenant, &block| block.call }
    end

    it 'returns a single Result for the given tenant' do
      result = migrator.migrate_one('acme')
      expect(result).to(be_a(Apartment::Migrator::Result))
      expect(result.tenant).to(eq('acme'))
      expect(result.status).to(eq(:success))
    end

    it 'switches to the given tenant' do
      migrator.migrate_one('acme')
      expect(Apartment::Tenant).to(have_received(:switch).with('acme'))
    end

    it 'sets Current.migrating during execution' do
      migrating_during = nil
      allow(Apartment::Tenant).to(receive(:switch)) do |&block|
        migrating_during = Apartment::Current.migrating
        block&.call
      end
      migrator.migrate_one('acme')
      expect(migrating_during).to(be(true))
    end

    it 'clears Current.migrating after completion' do
      migrator.migrate_one('acme')
      expect(Apartment::Current.migrating).to(be_falsey)
    end

    it 'disables advisory locks' do
      migrator.migrate_one('acme')
      expect(mock_connection).to(have_received(:instance_variable_set)
        .with(:@advisory_locks_enabled, false))
    end

    it 'instruments the migration' do
      migrator.migrate_one('acme')
      expect(Apartment::Instrumentation).to(have_received(:instrument)
        .with(:migrate_tenant, hash_including(tenant: 'acme')))
    end

    it 'returns :skipped when no pending migrations' do
      allow(mock_migration_context).to(receive(:needs_migration?).and_return(false))
      result = migrator.migrate_one('acme')
      expect(result.status).to(eq(:skipped))
    end

    it 'captures errors and returns :failed' do
      allow(mock_migration_context).to(receive(:migrate).and_raise(StandardError, 'boom'))
      result = migrator.migrate_one('acme')
      expect(result.status).to(eq(:failed))
      expect(result.error.message).to(eq('boom'))
    end

    it 'respects version parameter' do
      migrator = described_class.new(version: 20_260_401_000_000)
      expect(mock_migration_context).to(receive(:migrate).with(20_260_401_000_000).and_return([]))
      migrator.migrate_one('acme')
    end

    it 'calls evict_migration_pools in ensure' do
      Apartment.configure do |c|
        c.tenant_strategy = :schema
        c.tenants_provider = -> { [] }
        c.default_tenant = 'public'
        c.migration_role = :db_manager
      end
      pool_manager = instance_double(Apartment::PoolManager)
      allow(Apartment).to(receive(:pool_manager).and_return(pool_manager))
      allow(pool_manager).to(receive(:evict_by_role).and_return([]))

      migrator = described_class.new
      migrator.migrate_one('acme')

      expect(pool_manager).to(have_received(:evict_by_role).with(:db_manager))
    end
  end

  describe '#run with threads > 0' do
    let(:migrator) { described_class.new(threads: 4) }
    let(:mock_migration_context) { instance_double('ActiveRecord::MigrationContext') }
    let(:mock_pool) { instance_double('ActiveRecord::ConnectionAdapters::ConnectionPool') }
    let(:mock_connection) { double('connection') }

    before do
      Apartment.configure do |c|
        c.tenant_strategy = :schema
        c.tenants_provider = -> { (1..8).map { |i| "tenant_#{i}" } }
        c.default_tenant = 'public'
      end

      allow(ActiveRecord::Base).to(receive_messages(connection_pool: mock_pool, lease_connection: mock_connection))
      allow(mock_connection).to(receive(:instance_variable_get).and_return(true))
      allow(mock_connection).to(receive(:instance_variable_set))
      allow(mock_pool).to(receive(:migration_context).and_return(mock_migration_context))
      allow(mock_migration_context).to(receive_messages(needs_migration?: true, migrate: []))
      allow(Apartment::Instrumentation).to(receive(:instrument))
      allow(Apartment::Tenant).to(receive(:switch)) { |_tenant, &block| block.call }
    end

    it 'migrates all tenants plus primary' do
      result = migrator.run
      expect(result.results.size).to(eq(9))
    end

    it 'records thread count in MigrationRun' do
      result = migrator.run
      expect(result.threads).to(eq(4))
    end

    it 'captures tenant errors without halting parallel run' do
      call_count = Concurrent::AtomicFixnum.new(0)
      allow(mock_migration_context).to(receive(:migrate)) do
        raise(StandardError, 'boom') if call_count.increment == 3

        []
      end
      result = migrator.run
      expect(result.failed.size).to(eq(1))
      expect(result.results.size).to(eq(9))
    end
  end
end
