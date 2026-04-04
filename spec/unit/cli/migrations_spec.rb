# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../lib/apartment/cli'

RSpec.describe(Apartment::CLI::Migrations) do
  before do
    Apartment.configure do |c|
      c.tenant_strategy = :schema
      c.tenants_provider = -> { %w[acme beta] }
      c.default_tenant = 'public'
    end
  end

  def run_command(*args)
    output = StringIO.new
    $stdout = output
    described_class.start(args)
    output.string
  ensure
    $stdout = STDOUT
  end

  describe 'migrate' do
    let(:migration_run) do
      Apartment::Migrator::MigrationRun.new(
        results: [
          Apartment::Migrator::Result.new(
            tenant: 'public', status: :success, duration: 0.1, error: nil, versions_run: []
          ),
          Apartment::Migrator::Result.new(
            tenant: 'acme', status: :success, duration: 0.2, error: nil, versions_run: []
          ),
        ],
        total_duration: 0.3,
        threads: 0
      )
    end

    context 'without tenant argument (all tenants)' do
      before do
        allow(Apartment::Migrator).to(receive(:new).and_return(double(run: migration_run)))
        allow(ActiveRecord).to(receive(:dump_schema_after_migration).and_return(false))
      end

      it 'delegates to Migrator#run' do
        run_command('migrate')
        expect(Apartment::Migrator).to(have_received(:new))
      end

      it 'prints the migration summary' do
        output = run_command('migrate')
        expect(output).to(include('tenants'))
      end

      it 'passes --threads to Migrator' do
        expect(Apartment::Migrator).to(receive(:new)
          .with(hash_including(threads: 4)).and_return(double(run: migration_run)))
        run_command('migrate', '--threads=4')
      end

      it 'passes --version to Migrator' do
        expect(Apartment::Migrator).to(receive(:new)
          .with(hash_including(version: 20_260_401)).and_return(double(run: migration_run)))
        run_command('migrate', '--version=20260401')
      end

      it 'falls back to ENV VERSION when --version not given' do
        original = ENV.fetch('VERSION', nil)
        ENV['VERSION'] = '20260401'
        expect(Apartment::Migrator).to(receive(:new)
          .with(hash_including(version: 20_260_401)).and_return(double(run: migration_run)))
        run_command('migrate')
      ensure
        ENV['VERSION'] = original
      end

      it 'defaults threads to config value' do
        Apartment.configure do |c|
          c.tenant_strategy = :schema
          c.tenants_provider = -> { %w[acme] }
          c.default_tenant = 'public'
          c.parallel_migration_threads = 8
        end
        expect(Apartment::Migrator).to(receive(:new)
          .with(hash_including(threads: 8)).and_return(double(run: migration_run)))
        run_command('migrate')
      end

      it 'exits non-zero when migration fails' do
        failed_run = Apartment::Migrator::MigrationRun.new(
          results: [
            Apartment::Migrator::Result.new(
              tenant: 'acme', status: :failed, duration: 0.1,
              error: StandardError.new('boom'), versions_run: []
            ),
          ],
          total_duration: 0.1,
          threads: 0
        )
        allow(Apartment::Migrator).to(receive(:new).and_return(double(run: failed_run)))
        expect { run_command('migrate') }.to(raise_error(SystemExit))
      end
    end

    context 'with tenant argument (single tenant)' do
      let(:result) do
        Apartment::Migrator::Result.new(
          tenant: 'acme', status: :success, duration: 0.2, error: nil, versions_run: [1]
        )
      end

      before do
        allow(Apartment::Migrator).to(receive(:new).and_return(double(migrate_one: result)))
      end

      it 'delegates to Migrator#migrate_one' do
        migrator = double
        allow(Apartment::Migrator).to(receive(:new).and_return(migrator))
        expect(migrator).to(receive(:migrate_one).with('acme').and_return(result))
        run_command('migrate', 'acme')
      end

      it 'prints success message' do
        output = run_command('migrate', 'acme')
        expect(output).to(include('acme'))
      end

      it 'exits non-zero on failure' do
        failed = Apartment::Migrator::Result.new(
          tenant: 'acme', status: :failed, duration: 0.1,
          error: StandardError.new('boom'), versions_run: []
        )
        allow(Apartment::Migrator).to(receive(:new).and_return(double(migrate_one: failed)))
        expect { run_command('migrate', 'acme') }.to(raise_error(SystemExit))
      end
    end
  end

  describe 'rollback' do
    let(:mock_migration_context) { double('MigrationContext') }
    let(:mock_pool) { double('pool', migration_context: mock_migration_context) }

    before do
      allow(mock_migration_context).to(receive(:rollback))
      allow(ActiveRecord::Base).to(receive(:connection_pool).and_return(mock_pool))
      allow(Apartment::Tenant).to(receive(:switch)) { |_t, &block| block.call }
    end

    it 'rolls back all tenants by default' do
      run_command('rollback')
      expect(Apartment::Tenant).to(have_received(:switch).with('acme'))
      expect(Apartment::Tenant).to(have_received(:switch).with('beta'))
      expect(mock_migration_context).to(have_received(:rollback).with(1).twice)
    end

    it 'rolls back a single tenant when given' do
      run_command('rollback', 'acme')
      expect(Apartment::Tenant).to(have_received(:switch).with('acme'))
      expect(Apartment::Tenant).not_to(have_received(:switch).with('beta'))
    end

    it 'respects --step option' do
      run_command('rollback', '--step=3')
      expect(mock_migration_context).to(have_received(:rollback).with(3).twice)
    end

    it 'exits non-zero when a tenant fails' do
      allow(Apartment::Tenant).to(receive(:switch).with('acme')
        .and_raise(StandardError, 'boom'))
      allow(Apartment::Tenant).to(receive(:switch).with('beta')) { |_t, &block| block.call }
      expect { run_command('rollback') }.to(raise_error(SystemExit))
    end
  end
end
