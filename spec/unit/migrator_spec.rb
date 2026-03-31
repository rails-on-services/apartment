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
      versions_run: [20260401000000, 20260402000000]
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
    expect(result.versions_run).to(eq([20260401000000, 20260402000000]))
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

  describe '#resolve_migration_config' do
    let(:migrator) { described_class.new(threads: 0) }

    it 'returns base config when migration_db_config is nil' do
      base = { 'adapter' => 'postgresql', 'database' => 'app_db', 'schema_search_path' => 'acme' }
      result = migrator.send(:resolve_migration_config, base, nil)
      expect(result).to(eq(base))
    end

    it 'overlays credentials from migration_db_config' do
      base = { 'adapter' => 'postgresql', 'database' => 'app_db', 'schema_search_path' => 'acme',
               'username' => 'app_user', 'password' => 'app_pass' }
      migration_config = { adapter: 'postgresql', database: 'app_db',
                           username: 'db_manager', password: 'mgr_pass' }

      result = migrator.send(:resolve_migration_config, base, migration_config)

      expect(result['username']).to(eq('db_manager'))
      expect(result['password']).to(eq('mgr_pass'))
      expect(result['schema_search_path']).to(eq('acme'))
      expect(result['database']).to(eq('app_db'))
    end

    it 'overlays host when migration config specifies one' do
      base = { 'adapter' => 'postgresql', 'host' => 'app-host', 'username' => 'app' }
      migration_config = { adapter: 'postgresql', host: 'admin-host', username: 'admin', password: 'pass' }

      result = migrator.send(:resolve_migration_config, base, migration_config)
      expect(result['host']).to(eq('admin-host'))
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

    it 'accepts migration_db_config parameter' do
      migrator = described_class.new(migration_db_config: :db_manager)
      expect(migrator.instance_variable_get(:@migration_db_config)).to(eq(:db_manager))
    end
  end

  describe '#run' do
    let(:migrator) { described_class.new(threads: 0) }
    let(:mock_adapter) { instance_double('Apartment::Adapters::AbstractAdapter') }
    let(:mock_migration_context) { instance_double('ActiveRecord::MigrationContext') }
    let(:mock_pool) { instance_double('ActiveRecord::ConnectionAdapters::ConnectionPool') }

    before do
      allow(Apartment).to(receive(:adapter).and_return(mock_adapter))
      allow(mock_adapter).to(receive(:resolve_connection_config)) do |tenant|
        { 'adapter' => 'postgresql', 'schema_search_path' => tenant }
      end

      allow_any_instance_of(Apartment::PoolManager).to(receive(:fetch_or_create).and_return(mock_pool))
      allow_any_instance_of(Apartment::PoolManager).to(receive(:clear))
      allow(mock_pool).to(receive(:migration_context).and_return(mock_migration_context))
      allow(mock_pool).to(receive(:disconnect!))
      allow(mock_migration_context).to(receive(:needs_migration?).and_return(true))
      allow(mock_migration_context).to(receive(:migrate).and_return([]))
      allow(Apartment::Instrumentation).to(receive(:instrument))
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

    it 'captures errors without halting the run' do
      call_count = 0
      allow(mock_migration_context).to(receive(:migrate)) do
        call_count += 1
        raise(StandardError, 'boom') if call_count == 1
        []
      end
      result = migrator.run
      expect(result.failed.size).to(be >= 1)
      expect(result.results.size).to(eq(3))
    end

    it 'instruments each migration' do
      expect(Apartment::Instrumentation).to(receive(:instrument)
        .with(:migrate_tenant, hash_including(:tenant)).at_least(3).times)
      migrator.run
    end

    it 'clears the pool manager after run' do
      pool_manager = migrator.instance_variable_get(:@pool_manager)
      expect(pool_manager).to(receive(:clear))
      migrator.run
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
end
