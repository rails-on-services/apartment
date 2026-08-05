# frozen_string_literal: true

require 'spec_helper'
require_relative 'support'
require 'apartment/migrator'

# The user-visible half of the ConnectionRegistry patch: cold tenant pool
# creation while another thread is iterating ActiveRecord's pools. Rails does
# that iteration at the end of every request or job
# (ConnectionPool::ExecutorHooks.complete), on every executor run
# (ActiveRecord::QueryCache), and on its own reaper timer — so in a threaded
# server it overlaps cold creates routinely, and parallel migration is simply
# the densest producer of them.
#
# Both examples pin the overlap deterministically: an iterator thread parks
# inside the iteration block and the tenant work happens while it sits there.
# Without the patch the tenant side fails with
# `RuntimeError: can't add a new key into hash during iteration`, surfaced as an
# Apartment::ApartmentError from the switch.
#
# Tagged :stress to opt out of the per-example ConnectionHandler swap. That swap
# assigns ActiveRecord::Base.connection_handler, which lives in thread-isolated
# state, so threads the example spawns fall back to the process default and end
# up registering shards in a DIFFERENT registry from the one being iterated —
# the overlap disappears and the example passes against unpatched ActiveRecord.
# Production has exactly one handler for all threads; :stress reproduces that.
#
# Run via appraisal:
#   bundle exec appraisal rails-8.1-sqlite3 rspec spec/integration/v4/connection_registry_spec.rb
RSpec.describe('v4 AR connection registry concurrency', :integration, :stress,
               skip: (V4_INTEGRATION_AVAILABLE ? false : 'requires ActiveRecord + database gem')) do
  include V4IntegrationHelper

  let(:tmp_dir) { Dir.mktmpdir('apartment_registry') }
  let(:migrations_dir) { File.join(tmp_dir, 'migrate') }
  let(:tenants) { %w[registry_a registry_b] }
  let(:original_migrations_paths) { ActiveRecord::Migrator.migrations_paths.dup }

  before do
    write_test_migration(migrations_dir)
    ActiveRecord::Migrator.migrations_paths = [migrations_dir]

    V4IntegrationHelper.ensure_test_database! unless V4IntegrationHelper.sqlite?
    config = V4IntegrationHelper.establish_default_connection!(tmp_dir: tmp_dir)
    V4IntegrationHelper.create_test_table!

    stub_const('Widget', Class.new(ActiveRecord::Base) do
      self.table_name = 'widgets'
    end)

    Apartment.configure do |c|
      c.tenant_strategy = V4IntegrationHelper.tenant_strategy
      c.tenants_provider = -> { tenants }
      c.default_tenant = V4IntegrationHelper.default_tenant
      c.check_pending_migrations = false
    end

    Apartment.adapter = V4IntegrationHelper.build_adapter(config)
    Apartment.activate!

    tenants.each do |tenant|
      Apartment.adapter.create(tenant)
      Apartment::Tenant.switch(tenant) do
        V4IntegrationHelper.create_test_table!('widgets', connection: ActiveRecord::Base.connection)
      end
    end
  end

  after do
    ActiveRecord::Migrator.migrations_paths = original_migrations_paths
    Apartment::Tenant.reset
    # :stress skips the per-example ConnectionHandler swap, so anything left
    # registered here outlives this file. clear_config only deregisters what
    # Apartment's own manager still tracks, which misses pools a Migrator run
    # already evicted from it.
    ar_tenant_pool_keys.each { |pool_key| Apartment.deregister_shard(pool_key) }
    V4IntegrationHelper.cleanup_tenants!(tenants, Apartment.adapter)
    Apartment.clear_config
    Apartment::Current.reset
    if V4IntegrationHelper.sqlite?
      ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
      FileUtils.rm_rf(tmp_dir)
    end
  end

  it 'routes a cold tenant switch while another thread iterates AR pools' do
    discard_tenant_pools!

    with_pool_iteration_held do
      expect { Apartment::Tenant.switch('registry_a') { Widget.count } }.not_to(raise_error)
    end
  end

  it 'migrates tenants in parallel while another thread iterates AR pools' do
    discard_tenant_pools!

    run = with_pool_iteration_held { Apartment::Migrator.new(threads: 2).run }

    expect(run.failed).to(be_empty)
    expect(run).to(be_success)
  end

  # Forces the next switch for each tenant to be a cold create — the only path
  # that ADDS a shard key to AR's registry, and the only one MRI's iteration
  # guard reacts to. Replacing an existing key is allowed during iteration, so a
  # shard left behind by a sibling example would make these examples pass against
  # unpatched ActiveRecord. Both registries are cleared, and emptiness is
  # asserted rather than assumed.
  #
  # AR's side needs clearing explicitly because :stress skips the per-example
  # ConnectionHandler swap, so its registry outlives the example — and
  # reset_tenant_pools! only deregisters what Apartment's own manager still
  # tracks, which is nothing once a sibling example has evicted its pools.
  def discard_tenant_pools!
    Apartment.reset_tenant_pools!
    ar_tenant_pool_keys.each { |pool_key| Apartment.deregister_shard(pool_key) }

    expect(Apartment.pool_manager.stats[:total_pools]).to(eq(0))
    expect(ar_tenant_pool_keys).to(be_empty)
  end

  # The "tenant:role" keys AR still has registered, recovered from each pool's
  # db_config name (which Apartment builds as "<shard_key_prefix>_<pool_key>").
  def ar_tenant_pool_keys
    prefix = "#{Apartment.config.shard_key_prefix}_"

    ActiveRecord::Base.connection_handler
      .connection_pool_list(:all)
      .map { |pool| pool.db_config.name.to_s }
      .select { |name| name.start_with?(prefix) }
      .map { |name| name.delete_prefix(prefix) }
  end

  # Parks a thread inside ActiveRecord's pool iteration, runs the block while it
  # sits there, then releases it. Returns the block's value.
  #
  # The handler is captured here, in the example's thread, and handed to the
  # iterator: AR reads connection_handler out of thread-isolated state, so a
  # fresh thread would see the process default rather than the per-example
  # handler the :integration hook swaps in — and iterate an empty registry.
  def with_pool_iteration_held
    handler = ActiveRecord::Base.connection_handler
    iterating = Queue.new
    release = Queue.new

    iterator = Thread.new do # rubocop:disable ThreadSafety/NewThread
      parked = false
      handler.each_connection_pool do |_pool|
        next if parked

        parked = true
        iterating << :inside
        release.pop
      end
    end

    # Bounded so a future change that stops the iterator from ever yielding
    # fails the example instead of hanging the suite.
    raise('iterator thread never entered AR pool iteration') if iterating.pop(timeout: 10).nil?

    yield
  ensure
    release << :go
    iterator&.join(10)
  end

  def write_test_migration(dir)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, '20240101000001_create_registry_widgets.rb'), <<~RUBY)
      # frozen_string_literal: true
      class CreateRegistryWidgets < ActiveRecord::Migration[7.0]
        def change
          create_table(:registry_widgets, force: true) do |t|
            t.string :name
          end
        end
      end
    RUBY
  end
end
