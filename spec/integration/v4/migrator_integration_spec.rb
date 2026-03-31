# frozen_string_literal: true

require 'spec_helper'
require_relative 'support'
require 'apartment/migrator'

# Migrator integration tests require a real database and Rails environment.
# Run via appraisal:
#   bundle exec appraisal rails-8.1-sqlite3 rspec spec/integration/v4/migrator_integration_spec.rb
#
# PostgreSQL and MySQL also work; SQLite is simplest (no external DB).
RSpec.describe('v4 Migrator integration', :integration,
               skip: (V4_INTEGRATION_AVAILABLE ? false : 'requires ActiveRecord + database gem')) do
  include V4IntegrationHelper

  let(:tmp_dir) { Dir.mktmpdir('apartment_migrator') }
  let(:migrations_dir) { File.join(tmp_dir, 'migrate') }
  let(:test_tenants) { %w[migrate_test_a migrate_test_b migrate_test_c] }
  let(:original_migrations_paths) { ActiveRecord::Migrator.migrations_paths.dup }

  # Writes a trivial reversible migration into the given directory.
  def write_test_migration(dir)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, '20240101000001_create_migrator_test_widgets.rb'), <<~RUBY)
      # frozen_string_literal: true
      class CreateMigratorTestWidgets < ActiveRecord::Migration[7.0]
        def change
          create_table(:migrator_test_widgets, force: true) do |t|
            t.string :name
          end
        end
      end
    RUBY
  end

  before do
    write_test_migration(migrations_dir)

    # Point all AR migration contexts at our temp directory for this test.
    ActiveRecord::Migrator.migrations_paths = [migrations_dir]

    V4IntegrationHelper.ensure_test_database! unless V4IntegrationHelper.sqlite?
    config = V4IntegrationHelper.establish_default_connection!(tmp_dir: tmp_dir)

    Apartment.configure do |c|
      c.tenant_strategy = V4IntegrationHelper.tenant_strategy
      c.tenants_provider = -> { test_tenants }
      c.default_tenant = V4IntegrationHelper.default_tenant
    end

    Apartment.adapter = V4IntegrationHelper.build_adapter(config)
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

  describe 'sequential migration (threads: 0)' do
    it 'returns a MigrationRun covering all tenants' do
      migrator = Apartment::Migrator.new(threads: 0)
      run = migrator.run

      expect(run).to(be_a(Apartment::Migrator::MigrationRun))
      expect(run.threads).to(eq(0))
      expect(run).to(be_success)

      tenant_results = run.results.reject { |r| r.tenant == Apartment.config.default_tenant }
      expect(tenant_results.size).to(eq(test_tenants.size))
    end

    it 'marks each tenant :success or :skipped with no error' do
      run = Apartment::Migrator.new(threads: 0).run

      run.results.each do |result|
        expect(result).to(be_a(Apartment::Migrator::Result))
        expect(%i[success skipped]).to(include(result.status))
        expect(result.error).to(be_nil)
        expect(result.duration).to(be >= 0)
      end
    end

    it 'includes a result for the primary (default) tenant' do
      run = Apartment::Migrator.new(threads: 0).run

      primary = run.results.find { |r| r.tenant == Apartment.config.default_tenant }
      expect(primary).not_to(be_nil)
      expect(%i[success skipped]).to(include(primary.status))
    end

    it 'returns a non-empty summary string' do
      run = Apartment::Migrator.new(threads: 0).run

      expect(run.summary).to(be_a(String))
      expect(run.summary).not_to(be_empty)
      expect(run.summary).to(include('tenant'))
    end
  end

  describe 'parallel migration (threads: 2)' do
    it 'returns a MigrationRun covering all tenants' do
      migrator = Apartment::Migrator.new(threads: 2)
      run = migrator.run

      expect(run).to(be_a(Apartment::Migrator::MigrationRun))
      expect(run.threads).to(eq(2))
      expect(run).to(be_success)

      tenant_results = run.results.reject { |r| r.tenant == Apartment.config.default_tenant }
      expect(tenant_results.size).to(eq(test_tenants.size))
    end

    it 'produces no failures and records a positive total_duration' do
      run = Apartment::Migrator.new(threads: 2).run

      expect(run.failed).to(be_empty)
      expect(run.total_duration).to(be > 0)
    end

    it 'marks each tenant :success or :skipped with no error' do
      run = Apartment::Migrator.new(threads: 2).run

      run.results.each do |result|
        expect(%i[success skipped]).to(include(result.status))
        expect(result.error).to(be_nil)
      end
    end
  end

  describe 'idempotency' do
    it 'returns all :skipped results on a second run' do
      first_run = Apartment::Migrator.new(threads: 0).run
      expect(first_run).to(be_success)

      second_run = Apartment::Migrator.new(threads: 0).run
      expect(second_run).to(be_success)

      second_run.results.each do |result|
        expect(result.status).to(eq(:skipped)),
          "Expected '#{result.tenant}' to be :skipped on second run, got :#{result.status}"
      end
    end

    it 'idempotency holds under parallel execution as well' do
      Apartment::Migrator.new(threads: 2).run

      second_run = Apartment::Migrator.new(threads: 2).run
      expect(second_run).to(be_success)
      second_run.results.each do |result|
        expect(result.status).to(eq(:skipped))
      end
    end
  end
end
