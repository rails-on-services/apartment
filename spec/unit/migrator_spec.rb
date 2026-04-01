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
  subject(:run) do
    described_class.new(
      results: [success_result, failed_result, skipped_result],
      total_duration: 2.5,
      threads: 4
    )
  end

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

    it 'returns true when no failures' do
      all_good = described_class.new(
        results: [success_result, skipped_result], total_duration: 1.0, threads: 2
      )
      expect(all_good.success?).to(be(true))
    end
  end

  describe '#summary' do
    it 'includes counts and timing' do
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

RSpec.describe(Apartment::Migrator) do
  before do
    Apartment.configure do |c|
      c.tenant_strategy = :schema
      c.tenants_provider = -> { %w[acme beta] }
      c.default_tenant = 'public'
    end
  end

  describe '#initialize' do
    it 'defaults to 0 threads' do
      migrator = described_class.new
      expect(migrator.instance_variable_get(:@threads)).to(eq(0))
    end

    it 'accepts threads parameter' do
      migrator = described_class.new(threads: 8)
      expect(migrator.instance_variable_get(:@threads)).to(eq(8))
    end
  end

  describe '#run' do
    let(:migrator) { described_class.new(threads: 0) }
    let(:mock_migration_context) { instance_double('ActiveRecord::MigrationContext') }
    let(:mock_pool) { instance_double('ActiveRecord::ConnectionAdapters::ConnectionPool') }
    let(:mock_connection) { double('connection') }

    before do
      allow(ActiveRecord::Base).to(receive_messages(connection_pool: mock_pool, lease_connection: mock_connection))
      allow(mock_connection).to(receive(:instance_variable_set))
      allow(mock_pool).to(receive(:migration_context).and_return(mock_migration_context))
      allow(mock_migration_context).to(receive_messages(needs_migration?: true, migrate: []))
      allow(Apartment::Instrumentation).to(receive(:instrument))

      # Tenant.switch yields the block with Current.tenant set.
      # In unit tests, we stub it to just yield (no real connection swap).
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

        # Fail a tenant migration (call_count > 1 means primary already ran)
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

    it 'disables advisory locks for tenant migrations' do
      migrator.run
      # lease_connection is called for each tenant (not primary)
      expect(mock_connection).to(have_received(:instance_variable_set)
        .with(:@advisory_locks_enabled, false).at_least(:twice))
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
      allow(mock_connection).to(receive(:instance_variable_set))
      allow(mock_pool).to(receive(:migration_context).and_return(mock_migration_context))
      allow(mock_migration_context).to(receive_messages(needs_migration?: true, migrate: []))
      allow(Apartment::Instrumentation).to(receive(:instrument))
      allow(Apartment::Tenant).to(receive(:switch)) { |_tenant, &block| block.call }
    end

    it 'migrates all tenants plus primary' do
      result = migrator.run
      # 8 tenants + 1 primary = 9
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
