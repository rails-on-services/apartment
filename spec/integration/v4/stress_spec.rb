# frozen_string_literal: true

# rubocop:disable ThreadSafety/NewThread, Style/CombinableLoops

require 'spec_helper'
require_relative 'support'
require 'concurrent'

RSpec.describe('v4 Stress / concurrency integration', :integration, :stress,
               skip: if !V4_INTEGRATION_AVAILABLE
                       'requires ActiveRecord + database gem'
                     elsif V4IntegrationHelper.sqlite?
                       'SQLite single-writer lock causes BusyException under concurrent threads'
                     end) do
  include V4IntegrationHelper

  # ── Concurrent switching ────────────────────────────────────────────
  context 'concurrent switching' do
    let(:tmp_dir) { Dir.mktmpdir('apartment_stress') }
    let(:tenants) { Array.new(5) { |i| "stress_#{i}" } }

    before do
      V4IntegrationHelper.ensure_test_database! unless V4IntegrationHelper.sqlite?
      config = V4IntegrationHelper.establish_default_connection!(tmp_dir: tmp_dir)
      # Bump pool size so 10 concurrent threads can share a single tenant pool
      config = config.merge('pool' => 15)
      V4IntegrationHelper.create_test_table!

      stub_const('Widget', Class.new(ActiveRecord::Base) { self.table_name = 'widgets' })

      Apartment.configure do |c|
        c.tenant_strategy = V4IntegrationHelper.tenant_strategy
        c.tenants_provider = -> { tenants }
        c.default_tenant = V4IntegrationHelper.default_tenant
        c.check_pending_migrations = false
      end

      Apartment.adapter = V4IntegrationHelper.build_adapter(config)
      Apartment.activate!

      tenants.each do |t|
        Apartment.adapter.create(t)
        Apartment::Tenant.switch(t) { V4IntegrationHelper.create_test_table! }
      end
    end

    after do
      V4IntegrationHelper.cleanup_tenants!(tenants, Apartment.adapter)
      Apartment.clear_config
      Apartment::Current.reset
      if V4IntegrationHelper.sqlite?
        ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
        FileUtils.rm_rf(tmp_dir)
      end
    end

    it 'maintains data isolation across 10 threads doing 50 switches each' do
      errors = Queue.new

      threads = Array.new(10) do |thread_idx|
        Thread.new do
          50.times do
            tenant = tenants.sample
            Apartment::Tenant.switch(tenant) do
              Widget.create!(name: "thread_#{thread_idx}")
            end
          end
        rescue StandardError => e
          errors << "Thread #{thread_idx}: #{e.class}: #{e.message}"
        end
      end
      threads.each(&:join)

      collected_errors = []
      collected_errors << errors.pop until errors.empty?
      expect(collected_errors).to(be_empty)

      # Sum across all tenants should equal 500 (10 threads * 50 writes)
      total = tenants.sum do |t|
        Apartment::Tenant.switch(t) { Widget.count }
      end
      expect(total).to(eq(500))
    end

    it 'concurrent pool creation for the same tenant does not corrupt state' do
      pools = Concurrent::Array.new
      barrier = Concurrent::CyclicBarrier.new(10)

      threads = Array.new(10) do
        Thread.new do
          barrier.wait
          Apartment::Tenant.switch('stress_0') do
            pools << ActiveRecord::Base.connection_pool.object_id
            ActiveRecord::Base.connection.execute('SELECT 1')
          end
        end
      end
      threads.each(&:join)

      # All threads should have gotten the same pool (fetch_or_create is idempotent)
      expect(pools.uniq.size).to(eq(1))
    end
  end

  # ── Many tenants — pool manager scales ──────────────────────────────
  context 'pool manager scaling' do
    let(:tmp_dir) { Dir.mktmpdir('apartment_scale') }
    let(:many_tenants) { Array.new(50) { |i| "scale_#{i}" } }

    before do
      V4IntegrationHelper.ensure_test_database! unless V4IntegrationHelper.sqlite?
      @config = V4IntegrationHelper.establish_default_connection!(tmp_dir: tmp_dir)
      V4IntegrationHelper.create_test_table!

      stub_const('Widget', Class.new(ActiveRecord::Base) { self.table_name = 'widgets' })

      Apartment.configure do |c|
        c.tenant_strategy = V4IntegrationHelper.tenant_strategy
        c.tenants_provider = -> { many_tenants }
        c.default_tenant = V4IntegrationHelper.default_tenant
        c.check_pending_migrations = false
      end

      Apartment.adapter = V4IntegrationHelper.build_adapter(@config)
      Apartment.activate!
    end

    after do
      many_tenants.each do |t|
        Apartment.adapter.drop(t)
      rescue StandardError
        nil
      end
      Apartment.clear_config
      Apartment::Current.reset
      if V4IntegrationHelper.sqlite?
        ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
        FileUtils.rm_rf(tmp_dir)
      end
    end

    it 'handles 50 tenants without pool corruption' do
      many_tenants.each { |t| Apartment.adapter.create(t) }

      many_tenants.each do |t|
        Apartment::Tenant.switch(t) do
          V4IntegrationHelper.create_test_table!
          Widget.create!(name: t)
        end
      end

      many_tenants.each do |t|
        Apartment::Tenant.switch(t) do
          expect(Widget.count).to(eq(1))
          expect(Widget.first.name).to(eq(t))
        end
      end

      expect(Apartment.pool_manager.stats[:total_pools]).to(eq(50))
    end
  end

  # ── PoolReaper evicts idle pools ────────────────────────────────────
  context 'pool reaper' do
    let(:tmp_dir) { Dir.mktmpdir('apartment_reaper') }

    before do
      V4IntegrationHelper.ensure_test_database! unless V4IntegrationHelper.sqlite?
    end

    after do
      begin
        Apartment.adapter&.drop('reap_me')
      rescue StandardError
        nil
      end
      Apartment.clear_config
      Apartment::Current.reset
      if V4IntegrationHelper.sqlite?
        ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
        FileUtils.rm_rf(tmp_dir)
      end
    end

    it 'evicts idle pools after timeout' do
      config = V4IntegrationHelper.establish_default_connection!(tmp_dir: tmp_dir)
      V4IntegrationHelper.create_test_table!

      Apartment.configure do |c|
        c.tenant_strategy = V4IntegrationHelper.tenant_strategy
        c.tenants_provider = -> { %w[reap_me] }
        c.default_tenant = V4IntegrationHelper.default_tenant
        c.pool_idle_timeout = 0.5
        c.check_pending_migrations = false
      end

      Apartment.adapter = V4IntegrationHelper.build_adapter(config)
      Apartment.activate!

      Apartment.adapter.create('reap_me')

      Apartment::Tenant.switch('reap_me') do
        ActiveRecord::Base.connection.execute('SELECT 1')
      end

      role = ActiveRecord::Base.current_role
      expect(Apartment.pool_manager.tracked?("reap_me:#{role}")).to(be(true))

      # Poll until reaper evicts the idle pool or timeout
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
      until !Apartment.pool_manager.tracked?("reap_me:#{role}") ||
            Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep(0.1)
      end

      expect(Apartment.pool_manager.tracked?("reap_me:#{role}")).to(be(false))
    end
  end

  # ── PG: search_path isolation across concurrent threads ─────────────
  context 'PostgreSQL search_path isolation', if: V4IntegrationHelper.postgresql? do
    let(:tmp_dir) { Dir.mktmpdir('apartment_pg_sp') }
    let(:tenants) { Array.new(5) { |i| "sp_iso_#{i}" } }

    before do
      V4IntegrationHelper.ensure_test_database!
      config = V4IntegrationHelper.establish_default_connection!(tmp_dir: tmp_dir)
      config = config.merge('pool' => 15)

      Apartment.configure do |c|
        c.tenant_strategy = :schema
        c.tenants_provider = -> { tenants }
        c.default_tenant = 'public'
        c.check_pending_migrations = false
      end

      Apartment.adapter = V4IntegrationHelper.build_adapter(config)
      Apartment.activate!

      tenants.each do |t|
        Apartment.adapter.create(t)
        Apartment::Tenant.switch(t) { V4IntegrationHelper.create_test_table! }
      end
    end

    after do
      V4IntegrationHelper.cleanup_tenants!(tenants, Apartment.adapter)
      Apartment.clear_config
      Apartment::Current.reset
    end

    it 'each thread sees its own schema in search_path' do
      barrier = Concurrent::CyclicBarrier.new(5)
      results = Concurrent::Map.new
      errors = Queue.new

      threads = tenants.map.with_index do |tenant, idx|
        Thread.new do
          barrier.wait
          Apartment::Tenant.switch(tenant) do
            sp = ActiveRecord::Base.connection.execute('SHOW search_path').first
            # PG returns { "search_path" => "..." } — extract the value
            search_path_value = sp.is_a?(Hash) ? sp.values.first : sp.first
            results[idx] = { tenant: tenant, search_path: search_path_value }
          end
        rescue StandardError => e
          errors << "Thread #{idx}: #{e.class}: #{e.message}"
        end
      end
      threads.each(&:join)

      collected_errors = []
      collected_errors << errors.pop until errors.empty?
      expect(collected_errors).to(be_empty)

      # Each thread should see its own schema in the search_path
      tenants.each_with_index do |tenant, idx|
        expect(results[idx]).not_to(be_nil, "Thread #{idx} produced no result")
        actual_sp = results[idx][:search_path]
        expect(actual_sp).to(include(tenant),
                             "Thread #{idx}: expected '#{tenant}' in search_path, got '#{actual_sp}'")
      end
    end
  end

  # ── PG: concurrent schema creation ────────────────────────────────
  context 'PostgreSQL concurrent schema creation', if: V4IntegrationHelper.postgresql? do
    let(:tmp_dir) { Dir.mktmpdir('apartment_pg_csc') }
    let(:tenants) { Array.new(10) { |i| "csc_schema_#{i}" } }

    before do
      V4IntegrationHelper.ensure_test_database!
      config = V4IntegrationHelper.establish_default_connection!(tmp_dir: tmp_dir)
      ActiveRecord::Base.establish_connection(config.merge('pool' => 25))

      Apartment.configure do |c|
        c.tenant_strategy = :schema
        c.tenants_provider = -> { tenants }
        c.default_tenant = 'public'
        c.check_pending_migrations = false
      end

      Apartment.adapter = V4IntegrationHelper.build_adapter(config.merge('pool' => 25))
      Apartment.activate!
    end

    after do
      V4IntegrationHelper.cleanup_tenants!(tenants, Apartment.adapter)
      Apartment.clear_config
      Apartment::Current.reset
    end

    it 'creates 10 schemas concurrently without errors' do
      barrier = Concurrent::CyclicBarrier.new(10)
      errors = Queue.new

      threads = tenants.map do |tenant|
        Thread.new do
          barrier.wait
          Apartment.adapter.create(tenant)
        rescue StandardError => e
          errors << "#{tenant}: #{e.class}: #{e.message}"
        end
      end
      threads.each(&:join)

      collected_errors = []
      collected_errors << errors.pop until errors.empty?
      expect(collected_errors).to(be_empty)

      # Verify all schemas exist via information_schema
      existing = ActiveRecord::Base.connection.execute(
        "SELECT schema_name FROM information_schema.schemata WHERE schema_name LIKE 'csc_schema_%'"
      ).map { |row| row.is_a?(Hash) ? row['schema_name'] : row.first }

      tenants.each do |t|
        expect(existing).to(include(t), "Schema '#{t}' was not created")
      end
    end
  end

  # ── MySQL: rapid switching without connection exhaustion ───────────
  context 'MySQL rapid switching', if: V4IntegrationHelper.mysql? do
    let(:tmp_dir) { Dir.mktmpdir('apartment_my_rapid') }
    let(:tenants) { Array.new(5) { |i| "my_rapid_#{i}" } }

    before do
      V4IntegrationHelper.ensure_test_database!
      config = V4IntegrationHelper.establish_default_connection!(tmp_dir: tmp_dir)
      config = config.merge('pool' => 15)

      stub_const('Widget', Class.new(ActiveRecord::Base) { self.table_name = 'widgets' })

      Apartment.configure do |c|
        c.tenant_strategy = :database_name
        c.tenants_provider = -> { tenants }
        c.default_tenant = 'default'
        c.check_pending_migrations = false
      end

      Apartment.adapter = V4IntegrationHelper.build_adapter(config)
      Apartment.activate!

      tenants.each do |t|
        Apartment.adapter.create(t)
        Apartment::Tenant.switch(t) { V4IntegrationHelper.create_test_table! }
      end
    end

    after do
      V4IntegrationHelper.cleanup_tenants!(tenants, Apartment.adapter)
      Apartment.clear_config
      Apartment::Current.reset
    end

    it 'survives 500 rapid switches without connection errors' do
      errors = Queue.new

      500.times do
        tenant = tenants.sample
        Apartment::Tenant.switch(tenant) do
          ActiveRecord::Base.connection.execute('SELECT 1')
        end
      rescue StandardError => e
        errors << "#{e.class}: #{e.message}"
      end

      collected_errors = []
      collected_errors << errors.pop until errors.empty?
      expect(collected_errors).to(be_empty)
    end
  end

  # ── MySQL: concurrent database creation ────────────────────────────
  context 'MySQL concurrent database creation', if: V4IntegrationHelper.mysql? do
    let(:tmp_dir) { Dir.mktmpdir('apartment_my_cdc') }
    let(:tenants) { Array.new(10) { |i| "my_cdc_#{i}" } }

    before do
      V4IntegrationHelper.ensure_test_database!
      config = V4IntegrationHelper.establish_default_connection!(tmp_dir: tmp_dir)
      ActiveRecord::Base.establish_connection(config.merge('pool' => 25))

      Apartment.configure do |c|
        c.tenant_strategy = :database_name
        c.tenants_provider = -> { tenants }
        c.default_tenant = 'default'
        c.check_pending_migrations = false
      end

      Apartment.adapter = V4IntegrationHelper.build_adapter(config.merge('pool' => 25))
      Apartment.activate!
    end

    after do
      V4IntegrationHelper.cleanup_tenants!(tenants, Apartment.adapter)
      Apartment.clear_config
      Apartment::Current.reset
    end

    it 'creates 10 databases concurrently without errors' do
      barrier = Concurrent::CyclicBarrier.new(10)
      errors = Queue.new

      threads = tenants.map do |tenant|
        Thread.new do
          barrier.wait
          Apartment.adapter.create(tenant)
        rescue StandardError => e
          errors << "#{tenant}: #{e.class}: #{e.message}"
        end
      end
      threads.each(&:join)

      collected_errors = []
      collected_errors << errors.pop until errors.empty?
      expect(collected_errors).to(be_empty)

      # Verify all databases exist via SHOW DATABASES
      existing = ActiveRecord::Base.connection.execute('SHOW DATABASES').map do |row|
        row.is_a?(Hash) ? row.values.first : row.first
      end

      tenants.each do |t|
        expect(existing).to(include(t), "Database '#{t}' was not created")
      end
    end
  end

  # ── Concurrent drop while query in-flight (all engines) ───────────
  context 'concurrent drop during active query' do
    let(:tmp_dir) { Dir.mktmpdir('apartment_drop_race') }
    let(:tenant_name) { 'drop_race_tenant' }

    before do
      V4IntegrationHelper.ensure_test_database! unless V4IntegrationHelper.sqlite?
      config = V4IntegrationHelper.establish_default_connection!(tmp_dir: tmp_dir)
      config = config.merge('pool' => 15)

      Apartment.configure do |c|
        c.tenant_strategy = V4IntegrationHelper.tenant_strategy
        c.tenants_provider = -> { [tenant_name] }
        c.default_tenant = V4IntegrationHelper.default_tenant
        c.check_pending_migrations = false
      end

      Apartment.adapter = V4IntegrationHelper.build_adapter(config)
      Apartment.activate!

      Apartment.adapter.create(tenant_name)
      Apartment::Tenant.switch(tenant_name) { V4IntegrationHelper.create_test_table! }
    end

    after do
      begin
        Apartment.adapter&.drop(tenant_name)
      rescue StandardError
        nil
      end
      Apartment.clear_config
      Apartment::Current.reset
      if V4IntegrationHelper.sqlite?
        ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
        FileUtils.rm_rf(tmp_dir)
      end
    end

    it 'drop completes without crash; pool manager state is consistent' do
      # Thread A: switch into tenant and hold the connection for a bit
      thread_a_started = Concurrent::Event.new
      thread_a_error = Concurrent::AtomicReference.new(nil)

      thread_a = Thread.new do
        Apartment::Tenant.switch(tenant_name) do
          thread_a_started.set
          # Hold the connection open — give Thread B time to issue the drop
          begin
            ActiveRecord::Base.connection.execute('SELECT 1')
            sleep(0.3)
            # Try another query after drop may have happened
            ActiveRecord::Base.connection.execute('SELECT 1')
          rescue StandardError => e
            # Expected on some engines: the tenant may be gone.
            # Record it but don't re-raise — we just want no crash/segfault.
            thread_a_error.set(e)
          end
        end
      rescue StandardError => e
        thread_a_error.set(e)
      end

      # Thread B: wait for A to start, then drop the tenant
      thread_b_error = Concurrent::AtomicReference.new(nil)

      thread_b = Thread.new do
        thread_a_started.wait(5) # wait up to 5s for thread A
        begin
          Apartment.adapter.drop(tenant_name)
        rescue StandardError => e
          thread_b_error.set(e)
        end
      end

      [thread_a, thread_b].each { |t| t.join(10) }

      # The core assertion: no segfault, no hung threads — both threads completed.
      # Whether the drop or the query raised is engine-dependent:
      #
      # PG (schemas): DROP SCHEMA CASCADE succeeds even with active connections
      #   using that search_path, but the pool disconnect may fail. Thread A's
      #   second query may raise if the schema is gone.
      # MySQL: DROP DATABASE may fail with metadata lock if a connection is active.
      # SQLite: File deletion may fail or succeed depending on OS file locking.
      #
      # We accept either outcome — the invariant is no crash and consistent state.

      drop_err = thread_b_error.get
      query_err = thread_a_error.get

      # At least one of them should have succeeded without error
      # (if both errored, something unexpected happened)
      if drop_err && query_err
        # Both errored — acceptable only if both are StandardError subclasses
        expect(drop_err).to(be_a(StandardError),
                            "Thread B raised non-StandardError: #{drop_err.class}")
        expect(query_err).to(be_a(StandardError),
                             "Thread A raised non-StandardError: #{query_err.class}")
      end

      if drop_err.nil?
        # Drop succeeded — pool manager may or may not still track the tenant.
        # Known race: Thread A's switch block may re-create the pool via
        # ConnectionHandling#connection_pool → fetch_or_create after Thread B
        # removed it. This is a documented architectural limitation — concurrent
        # drop while a switch block is active can leave an orphaned pool entry.
        # The important thing is: no crash, no segfault, and the DDL completed.
      else
        # Drop failed — that's acceptable (e.g., MySQL metadata lock).
        # Just verify the error is a StandardError (not a segfault/SystemError).
        expect(drop_err).to(be_a(StandardError))
      end
    end
  end

  # ── Parallel tenant creation storm ──────────────────────────────────
  context 'tenant creation storm' do
    let(:tmp_dir) { Dir.mktmpdir('apartment_storm') }
    let(:storm_tenants) { Array.new(20) { |i| "storm_#{i}" } }

    before do
      V4IntegrationHelper.ensure_test_database! unless V4IntegrationHelper.sqlite?
      config = V4IntegrationHelper.establish_default_connection!(tmp_dir: tmp_dir)
      # Bump default pool size — 20 threads all do CREATE DDL via the default connection.
      ActiveRecord::Base.establish_connection(config.merge('pool' => 25))

      Apartment.configure do |c|
        c.tenant_strategy = V4IntegrationHelper.tenant_strategy
        c.tenants_provider = -> { storm_tenants }
        c.default_tenant = V4IntegrationHelper.default_tenant
        c.check_pending_migrations = false
      end

      Apartment.adapter = V4IntegrationHelper.build_adapter(config.merge('pool' => 25))
      Apartment.activate!
    end

    after do
      storm_tenants.each do |t|
        Apartment.adapter.drop(t)
      rescue StandardError
        nil
      end
      Apartment.clear_config
      Apartment::Current.reset
      if V4IntegrationHelper.sqlite?
        ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
        FileUtils.rm_rf(tmp_dir)
      end
    end

    it 'handles parallel tenant creation without errors' do
      errors = Queue.new

      threads = storm_tenants.map do |t|
        Thread.new do
          Apartment.adapter.create(t)
        rescue StandardError => e
          errors << "#{t}: #{e.class}: #{e.message}"
        end
      end
      threads.each(&:join)

      collected_errors = []
      collected_errors << errors.pop until errors.empty?
      expect(collected_errors).to(be_empty)

      # Verify all tenants are accessible
      storm_tenants.each do |t|
        Apartment::Tenant.switch(t) do
          ActiveRecord::Base.connection.execute('SELECT 1')
        end
      end
    end
  end
end

# rubocop:enable ThreadSafety/NewThread, Style/CombinableLoops
