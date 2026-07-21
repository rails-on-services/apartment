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
    config = V4IntegrationHelper.establish_default_connection!(tmp_dir: tmp_dir)

    Apartment.configure do |c|
      c.tenant_strategy = V4IntegrationHelper.tenant_strategy
      c.tenants_provider = -> { test_tenants }
      c.default_tenant = V4IntegrationHelper.default_tenant
      c.check_pending_migrations = false
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
    # Add a second migration that always raises, so migrate_tenant hits its rescue.
    File.write(File.join(migrations_dir, '20240101000002_boom.rb'), <<~RUBY)
      # frozen_string_literal: true
      class Boom < ActiveRecord::Migration[7.0]
        def change
          raise 'boom'
        end
      end
    RUBY

    run = Apartment::Migrator.new(threads: 0).run
    expect(run.failed).not_to(be_empty)

    test_tenants.each do |tenant|
      pool = tenant_pool(tenant)
      next if pool.nil?

      expect(busy_connections(pool)).to(eq(0))
      expect(open_transactions(pool)).to(eq(0))
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
end
