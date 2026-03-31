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
end
