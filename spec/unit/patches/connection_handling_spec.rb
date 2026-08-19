# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'

# This spec requires real ActiveRecord + sqlite3 gem (not the stub in apartment_spec.rb).
# Run via any sqlite3 appraisal, e.g.: bundle exec appraisal rails-8.1-sqlite3 rspec spec/unit/patches/
# Skips gracefully when sqlite3 is not available or when the AR stub from
# apartment_spec.rb loaded first (randomized suite order).
#
# CONNECTION_HANDLING_REQUIRED=1 turns that skip into a hard failure in the job that
# IS supposed to load the dep — the `unit` job, whose BUNDLE_GEMFILE is a sqlite3
# appraisal. Without it the default driverless bundle reports every example here as
# pending and green, and a CI bundle that quietly lost sqlite3 would read the same
# way. The examples this covers include the rescue-boundary guards on
# `#connection_pool`, the hottest path in the gem, so a guard that silently covers
# nothing is the exact failure the flag exists to prevent. Same idiom as
# PG_UNIT_REQUIRED and RAILTIE_SPEC_REQUIRED; see spec/CLAUDE.md.
REAL_AR_AVAILABLE = begin
  require('active_record')
  # The stub in apartment_spec.rb defines AR::Base without establish_connection.
  # If that loaded first, real AR's require is a partial no-op. Detect this.
  if ActiveRecord::Base.respond_to?(:establish_connection)
    ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
    require_relative('../../../lib/apartment/patches/connection_handling')
    ActiveRecord::Base.singleton_class.prepend(Apartment::Patches::ConnectionHandling)
    true
  else
    if ENV['CONNECTION_HANDLING_REQUIRED']
      raise('[connection_handling_spec] CONNECTION_HANDLING_REQUIRED is set but the AR ' \
            'stub loaded first (no establish_connection), so these examples would skip.')
    end

    warn '[connection_handling_spec] Skipping: AR stub loaded (no establish_connection)'
    false
  end
rescue LoadError => e
  raise if ENV['CONNECTION_HANDLING_REQUIRED']

  warn "[connection_handling_spec] Skipping: #{e.message}"
  false
end

unless REAL_AR_AVAILABLE
  module Apartment
    module Patches
      module ConnectionHandling; end
    end
  end
end

RSpec.describe(Apartment::Patches::ConnectionHandling) do
  before do
    skip 'requires real ActiveRecord with sqlite3 gem (run via appraisal)' unless REAL_AR_AVAILABLE
    Apartment.configure do |config|
      config.tenant_strategy = :schema
      config.tenants_provider = -> { %w[acme widgets] }
      config.default_tenant = 'public'
      config.check_pending_migrations = false
    end
    Apartment.adapter = mock_adapter
  end

  let(:mock_adapter) do
    # aborted_transaction? is consulted by the checkin heal on every connection
    # returned to a tenant pool. sqlite3 has no aborted-transaction state, so false
    # is also what the real Sqlite3Adapter answers here.
    double('AbstractAdapter',
           validated_connection_config: { 'adapter' => 'sqlite3', 'database' => ':memory:' },
           shared_pinned_connection?: false,
           aborted_transaction?: false)
  end

  # Capture the default pool with no tenant set, for comparison in tests.
  let(:default_pool) do
    Apartment::Current.tenant = nil
    ActiveRecord::Base.connection_pool
  end

  describe '#connection_pool' do
    context 'when tenant is nil' do
      it 'returns the default pool' do
        Apartment::Current.tenant = nil
        expect(ActiveRecord::Base.connection_pool).to(equal(default_pool))
      end
    end

    # The four `return super` guards run BEFORE any tenant resolution, so a failure
    # they surface is stock Rails' failure and must arrive as itself. A method-level
    # rescue covered them and relabelled every one as "Failed to resolve connection
    # pool for tenant ''" — an unrelated connection error reported as an Apartment
    # tenant-resolution failure, on the path most of a Rails app takes.
    #
    # `connected_to(role: :nope)` is how the defect was reported: the role resolves no
    # pool, so AR's own lookup raises. Asserted against ConnectionNotEstablished, not
    # the ConnectionNotDefined subclass Rails 8 raises, because that subclass does not
    # exist before Rails 8.0 and this spec runs on the Rails floor too.
    context 'when the default path raises' do
      it 'surfaces the error unwrapped for a nil tenant' do
        Apartment::Current.tenant = nil

        expect { ActiveRecord::Base.connected_to(role: :nope) { ActiveRecord::Base.connection_pool } }
          .to(raise_error(ActiveRecord::ConnectionNotEstablished))
      end

      it 'surfaces the error unwrapped for the default tenant' do
        Apartment::Current.tenant = 'public'

        expect { ActiveRecord::Base.connected_to(role: :nope) { ActiveRecord::Base.connection_pool } }
          .to(raise_error(ActiveRecord::ConnectionNotEstablished))
      end

      # Stubbed at Apartment.pool_manager rather than via clear_config, which also
      # nils the config and would leave guard 1 answering instead of this one.
      it 'surfaces the error unwrapped when there is no pool manager' do
        allow(Apartment).to(receive(:pool_manager).and_return(nil))
        Apartment::Current.tenant = 'acme'

        expect { ActiveRecord::Base.connected_to(role: :nope) { ActiveRecord::Base.connection_pool } }
          .to(raise_error(ActiveRecord::ConnectionNotEstablished))
      end

      it 'surfaces the error unwrapped for a pinned model on a separate pool' do
        require_relative('../../../lib/apartment/concerns/model')
        allow(mock_adapter).to(receive(:shared_pinned_connection?).and_return(false))
        pinned_class = Class.new(ActiveRecord::Base) do
          include Apartment::Model
        end
        stub_const('PinnedDefaultPathModel', pinned_class)
        pinned_class.pin_tenant
        Apartment::Current.tenant = 'acme'

        expect { ActiveRecord::Base.connected_to(role: :nope) { pinned_class.connection_pool } }
          .to(raise_error(ActiveRecord::ConnectionNotEstablished))
      end

      # The cfg half of guard 1, which the nil-tenant example above cannot reach: a
      # real tenant with no config at all. Apartment.clear_config nils the config, and
      # this case was relabelled before the fix too.
      it 'surfaces the error unwrapped for a real tenant with no config' do
        Apartment.clear_config
        Apartment::Current.tenant = 'acme'

        expect { ActiveRecord::Base.connected_to(role: :nope) { ActiveRecord::Base.connection_pool } }
          .to(raise_error(ActiveRecord::ConnectionNotEstablished))
      end

      # The adapter.nil? half of guard 4: a nil adapter falls back to the separate-pool
      # answer, so a pinned model takes the default path and shared_pinned_connection?
      # is never asked. Kept as a guard because deleting `adapter.nil? ||` would turn
      # that documented safe default into a NoMethodError.
      #
      # Stubbed rather than arranged, because a genuine nil is not producible:
      # Apartment.adapter is `@adapter ||= build_adapter`, and build_adapter either
      # returns an adapter or raises. Setting @adapter = nil does not help either — the
      # rebuild reads connection_db_config, which resolves connection_pool, which
      # re-enters this very method and recurses until SystemStackError. Unreachable in
      # practice for the same reason it is harmless: at boot Current.tenant is nil, so
      # guard 1 answers long before Apartment.adapter is read.
      it 'surfaces the error unwrapped for a pinned model when the adapter is nil' do
        require_relative('../../../lib/apartment/concerns/model')
        allow(Apartment).to(receive(:adapter).and_return(nil))
        pinned_class = Class.new(ActiveRecord::Base) do
          include Apartment::Model
        end
        stub_const('PinnedNoAdapterModel', pinned_class)
        pinned_class.pin_tenant
        Apartment::Current.tenant = 'acme'

        expect { ActiveRecord::Base.connected_to(role: :nope) { pinned_class.connection_pool } }
          .to(raise_error(ActiveRecord::ConnectionNotEstablished))
      end
    end

    # The boundary's other side. Everything below the guards is tenant-resolution work
    # and stays wrapped; narrowing the rescue must not have deleted that.
    context 'when the tenant path raises' do
      it 'still wraps a failure raised while resolving a tenant pool' do
        allow(mock_adapter).to(receive(:validated_connection_config).and_raise(RuntimeError, 'boom'))
        Apartment::Current.tenant = 'acme'

        expect { ActiveRecord::Base.connection_pool }.to(
          raise_error(Apartment::ApartmentError,
                      /Failed to resolve connection pool for tenant 'acme': RuntimeError: boom/)
        )
      end

      # A pinned model with shared_pinned_connection? true does NOT take guard 4's
      # return super — it falls through to the tenant path, so it is inside the
      # boundary and its failures wrap like any other tenant resolution.
      it 'still wraps for a pinned model sharing the tenant pool' do
        require_relative('../../../lib/apartment/concerns/model')
        allow(mock_adapter).to(receive(:shared_pinned_connection?).and_return(true))
        allow(mock_adapter).to(receive(:validated_connection_config).and_raise(RuntimeError, 'boom'))
        pinned_class = Class.new(ActiveRecord::Base) do
          include Apartment::Model
        end
        stub_const('PinnedSharedWrapModel', pinned_class)
        pinned_class.pin_tenant
        Apartment::Current.tenant = 'acme'

        expect { pinned_class.connection_pool }.to(
          raise_error(Apartment::ApartmentError,
                      /Failed to resolve connection pool for tenant 'acme': RuntimeError: boom/)
        )
      end

      # The base-config fallback, and the reason MigrationRole.wrap needs no unwrap:
      # inside the tenant path, `super` failing with ConnectionNotEstablished is
      # ABSORBED — base becomes nil and the adapter supplies its own config — so an
      # unregistered role never produces a wrapped error here. If this ever starts
      # raising, that comment in migration_role.rb is wrong.
      it 'absorbs a ConnectionNotEstablished from the default-pool lookup', :aggregate_failures do
        Apartment::Current.tenant = 'acme'

        pool = ActiveRecord::Base.connected_to(role: :nope) { ActiveRecord::Base.connection_pool }

        expect(pool).not_to(be_nil)
        expect(mock_adapter).to(have_received(:validated_connection_config)
          .with('acme', base_config_override: nil))
      end

      # Only that one class is absorbed. Anything else from the same lookup is
      # tenant-resolution work failing, so it wraps.
      it 'wraps any other failure from the default-pool lookup' do
        allow(ActiveRecord::Base.connection_handler).to(
          receive(:retrieve_connection_pool).and_raise(RuntimeError, 'handler exploded')
        )
        Apartment::Current.tenant = 'acme'

        expect { ActiveRecord::Base.connection_pool }.to(
          raise_error(Apartment::ApartmentError,
                      /Failed to resolve connection pool for tenant 'acme': RuntimeError: handler exploded/)
        )
      end
    end

    # The defect the base-config fallback hid. On the TENANT path an unregistered
    # ddl_role does not raise: `super` fails, `base` becomes nil, and the adapter
    # supplies its own config — so the pool is established with the DEFAULT
    # connection's credentials while its key still claims the elevated role. Every
    # per-tenant migration then runs as the application user under a label that lies,
    # which is the failure the create-under-ddl_role fix exists to prevent, arriving
    # by typo instead.
    context 'when ddl_role names an unregistered role' do
      def configure_ddl_role(role)
        Apartment.configure do |config|
          config.tenant_strategy = :schema
          config.tenants_provider = -> { %w[acme widgets] }
          config.default_tenant = 'public'
          config.check_pending_migrations = false
          config.ddl_role = role
        end
        # Reassigned because configure clears @adapter, and a rebuild would resolve the
        # default config through the guard-1 `super` — surfacing the unregistered role
        # from the BUILD rather than from the tenant-path fallback under test.
        Apartment.adapter = mock_adapter
      end

      it 'raises a ConfigurationError naming the key instead of fabricating a pool', :aggregate_failures do
        configure_ddl_role(:nope)
        Apartment::Current.tenant = 'acme'

        raised = nil
        begin
          ActiveRecord::Base.connected_to(role: :nope) { ActiveRecord::Base.connection_pool }
        rescue StandardError => e
          raised = e
        end

        expect(raised).to(be_a(Apartment::ConfigurationError))
        expect(raised.message).to(match(/ddl_role.*:nope/))
        # Raised inside the rescue, so ActiveRecord's own error stays as the cause.
        expect(raised.cause).to(be_a(ActiveRecord::ConnectionNotEstablished))
      end

      # Gated on the role being ddl_role. An unregistered :reading role fabricates the
      # same way, and that is a separate contract with its own specs — this fix must
      # not change it by accident.
      it 'leaves a non-ddl_role role to the existing fallback' do
        configure_ddl_role(:db_manager)
        Apartment::Current.tenant = 'acme'

        pool = ActiveRecord::Base.connected_to(role: :reading) { ActiveRecord::Base.connection_pool }

        expect(pool).not_to(be_nil)
      end

      # The probe is conservative by construction: it reports "registered" when it
      # cannot answer, so a probe failure can never turn into a spurious raise.
      it 'falls back rather than raising when the probe cannot answer' do
        configure_ddl_role(:nope)
        allow(ActiveRecord::Base).to(receive(:connection_handler).and_call_original)
        allow(Apartment::MigrationRole).to(receive(:role_pool_registered?).and_return(true))
        Apartment::Current.tenant = 'acme'

        pool = ActiveRecord::Base.connected_to(role: :nope) { ActiveRecord::Base.connection_pool }

        expect(pool).not_to(be_nil)
      end
    end

    context 'when tenant equals the default tenant' do
      it 'returns the default pool' do
        Apartment::Current.tenant = 'public'
        expect(ActiveRecord::Base.connection_pool).to(equal(default_pool))
      end
    end

    context 'when the tenant name is pool-key-unsafe' do
      # Validation must happen BEFORE pool_key construction and fetch_or_create:
      # in the capped path, fetch_or_admit calls admit! (which can LRU-evict an
      # idle pool) before the adapter's deeper validation runs. An invalid name
      # must be rejected before any admission/eviction side effect.
      it 'rejects the name before touching the pool manager' do
        Apartment::Current.tenant = 'bad:name'
        expect(Apartment.pool_manager).not_to(receive(:fetch_or_create))
        expect { ActiveRecord::Base.connection_pool }
          .to(raise_error(Apartment::ConfigurationError, /colon/))
      end
    end

    # Failure-class member 7 (W1). The heal lives on the pool, so it has to be
    # installed at pool creation -- after the post-establish checks (a pool that
    # fails them is discarded and must not be extended), before the pool is handed
    # out (so the very first checkin is covered).
    # Design: docs/designs/transaction-taint-detection.md
    context 'when a tenant pool is created' do
      it 'extends it with the checkin heal' do
        Apartment::Current.tenant = 'acme'
        expect(ActiveRecord::Base.connection_pool)
          .to(be_a(Apartment::TransactionTaint::PoolHeal))
      end

      it 'stamps it with the tenant and pool key for the event payload' do
        Apartment::Current.tenant = 'acme'
        pool = ActiveRecord::Base.connection_pool
        expect([pool.apartment_tenant, pool.apartment_pool_key])
          .to(eq(['acme', 'acme:writing']))
      end

      it 'leaves the pool unextended when heal_tainted_connections is false' do
        Apartment.configure do |config|
          config.tenant_strategy = :schema
          config.tenants_provider = -> { %w[acme widgets] }
          config.default_tenant = 'public'
          config.check_pending_migrations = false
          config.heal_tainted_connections = false
        end
        Apartment.adapter = mock_adapter

        Apartment::Current.tenant = 'acme'
        expect(ActiveRecord::Base.connection_pool)
          .not_to(be_a(Apartment::TransactionTaint::PoolHeal))
      end
    end

    context 'when an active tenant is set' do
      it 'returns a different pool from the default' do
        Apartment::Current.tenant = 'acme'
        tenant_pool = ActiveRecord::Base.connection_pool
        expect(tenant_pool).not_to(equal(default_pool))
      end

      it 'returns an ActiveRecord::ConnectionAdapters::ConnectionPool' do
        Apartment::Current.tenant = 'acme'
        expect(ActiveRecord::Base.connection_pool).to(
          be_a(ActiveRecord::ConnectionAdapters::ConnectionPool)
        )
      end
    end

    context 'caching' do
      it 'returns the same pool on repeated calls for the same tenant' do
        Apartment::Current.tenant = 'acme'
        pool1 = ActiveRecord::Base.connection_pool
        pool2 = ActiveRecord::Base.connection_pool
        expect(pool1).to(equal(pool2))
      end

      it 'returns different pools for different tenants' do
        Apartment::Current.tenant = 'acme'
        acme_pool = ActiveRecord::Base.connection_pool

        Apartment::Current.tenant = 'widgets'
        widgets_pool = ActiveRecord::Base.connection_pool

        expect(acme_pool).not_to(equal(widgets_pool))
      end
    end

    context 'AR ConnectionHandler registration' do
      it 'registers the pool under the namespaced shard key' do
        Apartment::Current.tenant = 'acme'
        ActiveRecord::Base.connection_pool

        role = ActiveRecord::Base.current_role
        shard_key = :"#{Apartment.config.shard_key_prefix}_acme:#{role}"
        registered = ActiveRecord::Base.connection_handler.retrieve_connection_pool(
          'ActiveRecord::Base',
          role: role,
          shard: shard_key
        )
        expect(registered).not_to(be_nil)
      end

      it 'stores the correct adapter in db_config' do
        Apartment::Current.tenant = 'acme'
        pool = ActiveRecord::Base.connection_pool
        expect(pool.db_config.adapter).to(eq('sqlite3'))
      end

      it 'deregister_all_tenant_pools removes AR handler entries' do
        # Create pools for two tenants
        Apartment::Current.tenant = 'acme'
        ActiveRecord::Base.connection_pool
        Apartment::Current.tenant = 'widgets'
        ActiveRecord::Base.connection_pool

        prefix = Apartment.config.shard_key_prefix

        role = ActiveRecord::Base.current_role

        # Verify they exist
        %w[acme widgets].each do |t|
          expect(ActiveRecord::Base.connection_handler.retrieve_connection_pool(
                   'ActiveRecord::Base', role: role, shard: :"#{prefix}_#{t}:#{role}"
                 )).not_to(be_nil)
        end

        # Deregister all
        Apartment.send(:deregister_all_tenant_pools)

        # Verify they're gone
        %w[acme widgets].each do |t|
          expect(ActiveRecord::Base.connection_handler.retrieve_connection_pool(
                   'ActiveRecord::Base', role: role, shard: :"#{prefix}_#{t}:#{role}"
                 )).to(be_nil)
        end
      end

      it 'deregisters the shard when a post-establish step raises (no orphaned pool)' do
        # Drive a failure *after* establish_connection has registered the shard by
        # making the per-tenant schema-cache load blow up. Without the rescue in
        # ConnectionHandling the pool would be left live in AR but untracked by
        # PoolManager — a leak that also undercounts max_total.
        Apartment.configure do |config|
          config.tenant_strategy = :schema
          config.tenants_provider = -> { %w[acme widgets] }
          config.default_tenant = 'public'
          config.check_pending_migrations = false
          config.schema_cache_per_tenant = true
        end
        Apartment.adapter = mock_adapter
        allow(Apartment::SchemaCache).to(receive(:cache_path_for).and_raise(StandardError, 'cache boom'))

        Apartment::Current.tenant = 'acme'
        role = ActiveRecord::Base.current_role
        shard_key = :"#{Apartment.config.shard_key_prefix}_acme:#{role}"

        expect { ActiveRecord::Base.connection_pool }.to(raise_error(Apartment::ApartmentError))

        expect(ActiveRecord::Base.connection_handler.retrieve_connection_pool(
                 'ActiveRecord::Base', role: role, shard: shard_key
               )).to(be_nil)
        expect(Apartment.pool_manager.tracked?("acme:#{role}")).to(be(false))
      end
    end

    context 'when schema_cache_per_tenant loads a real dump file' do
      around do |example|
        dir = Dir.mktmpdir
        @cache_path = File.join(dir, 'schema_cache_acme.yml')
        example.run
      ensure
        FileUtils.remove_entry(dir) if dir && File.directory?(dir)
      end

      it 'loads the per-tenant dump without raising (regression: BoundSchemaReflection#load! takes no args)' do
        # Warm acme's pool and dump its schema cache to a real file.
        Apartment::Current.tenant = 'acme'
        ActiveRecord::Base.connection.schema_cache.dump_to(@cache_path)
        # Force a fresh re-establish so the schema-cache load path runs on next resolve.
        role = ActiveRecord::Base.current_role
        Apartment.pool_manager.remove_tenant('acme')
        Apartment.deregister_shard("acme:#{role}")
        Apartment::Current.tenant = nil

        Apartment.configure do |config|
          config.tenant_strategy = :schema
          config.tenants_provider = -> { %w[acme widgets] }
          config.default_tenant = 'public'
          config.check_pending_migrations = false
          config.schema_cache_per_tenant = true
        end
        Apartment.adapter = mock_adapter
        allow(Apartment::SchemaCache).to(receive(:cache_path_for).with('acme').and_return(@cache_path))

        Apartment::Current.tenant = 'acme'
        expect { ActiveRecord::Base.connection_pool }.not_to(raise_error)
        pool = ActiveRecord::Base.connection_pool
        expect(pool.schema_reflection)
          .to(be_a(ActiveRecord::ConnectionAdapters::SchemaReflection))
      end
    end

    context 'pool usability' do
      it 'can execute a real query against the tenant pool' do
        Apartment::Current.tenant = 'acme'
        pool = ActiveRecord::Base.connection_pool
        result = pool.with_connection { |conn| conn.execute('SELECT 1 AS n') }
        expect(result.first['n']).to(eq(1))
      end
    end

    context 'PoolManager tracking' do
      it 'registers the pool in PoolManager' do
        Apartment::Current.tenant = 'acme'
        ActiveRecord::Base.connection_pool
        role = ActiveRecord::Base.current_role
        expect(Apartment.pool_manager.tracked?("acme:#{role}")).to(be(true))
      end

      it 'does not register the default tenant in PoolManager' do
        Apartment::Current.tenant = nil
        ActiveRecord::Base.connection_pool
        expect(Apartment.pool_manager.tracked?('public')).to(be(false))
      end
    end

    context 'when pool_manager is nil (unconfigured)' do
      it 'returns the default pool without raising' do
        Apartment.clear_config
        Apartment::Current.tenant = 'acme'
        expect { ActiveRecord::Base.connection_pool }.not_to(raise_error)
      end
    end

    describe 'Apartment.activate!' do
      it 'prepends ConnectionHandling on ActiveRecord::Base singleton class' do
        # activate! is idempotent (prepend is a no-op if already prepended)
        Apartment.activate!
        expect(ActiveRecord::Base.singleton_class.ancestors).to(include(described_class))
      end
    end

    context 'hyphenated tenant name' do
      let(:mock_adapter_hyph) do
        double('AbstractAdapter',
               validated_connection_config: { 'adapter' => 'sqlite3', 'database' => ':memory:' })
      end

      before do
        Apartment.configure do |config|
          config.tenant_strategy = :schema
          config.tenants_provider = -> { ['my-tenant'] }
          config.default_tenant = 'public'
          config.check_pending_migrations = false
        end
        Apartment.adapter = mock_adapter_hyph
      end

      it 'registers pool under the hyphenated shard key' do
        Apartment::Current.tenant = 'my-tenant'
        pool = ActiveRecord::Base.connection_pool
        expect(pool).not_to(be_nil)
        expect(pool).to(be_a(ActiveRecord::ConnectionAdapters::ConnectionPool))
      end

      it 'pool is tracked in PoolManager under the hyphenated key' do
        Apartment::Current.tenant = 'my-tenant'
        ActiveRecord::Base.connection_pool
        role = ActiveRecord::Base.current_role
        expect(Apartment.pool_manager.tracked?("my-tenant:#{role}")).to(be(true))
      end
    end

    context 'role interaction' do
      it 'registers pool under the default role and namespaced shard key' do
        Apartment::Current.tenant = 'acme'
        ActiveRecord::Base.connection_pool

        role = ActiveRecord::Base.current_role
        shard_key = :"#{Apartment.config.shard_key_prefix}_acme:#{role}"
        pool = ActiveRecord::Base.connection_handler.retrieve_connection_pool(
          'ActiveRecord::Base',
          role: role,
          shard: shard_key
        )
        expect(pool).not_to(be_nil)
        expect(pool).to(be_a(ActiveRecord::ConnectionAdapters::ConnectionPool))
      end
    end

    context 'role-aware pool keys' do
      it 'includes current_role in the pool key' do
        Apartment::Current.tenant = 'acme'
        ActiveRecord::Base.connection_pool

        # The pool key must be "tenant:role" — verify the role portion is present
        # (real role name; stubbing an undefined AR role breaks super resolution)
        role = ActiveRecord::Base.current_role
        expect(Apartment.pool_manager.tracked?("acme:#{role}")).to(be(true))
        # Confirm the key contains a colon-separated role, not just the tenant name
        keys = Apartment.pool_manager.instance_variable_get(:@pools).keys
        acme_key = keys.find { |k| k.start_with?('acme:') }
        expect(acme_key).to(match(/\Aacme:.+\z/))
      end
    end

    context 'pending migration check' do
      it 'is suppressed when check_pending_migrations is false' do
        Apartment::Current.tenant = 'acme'
        expect { ActiveRecord::Base.connection_pool }.not_to(raise_error)
      end
    end

    context 'pinned model bypass' do
      before do
        require_relative('../../../lib/apartment/concerns/model')
      end

      context 'when shared_pinned_connection? is false (separate pool)' do
        before do
          allow(mock_adapter).to(receive(:shared_pinned_connection?).and_return(false))
        end

        it 'returns the default pool for a pinned AR::Base subclass when tenant is set' do
          pinned_class = Class.new(ActiveRecord::Base) do
            include Apartment::Model
          end
          stub_const('PinnedBypassModel', pinned_class)
          pinned_class.pin_tenant

          Apartment::Current.tenant = 'acme'
          expect(pinned_class.connection_pool).to(equal(default_pool))
        end

        it 'bypasses for STI subclass of a pinned model' do
          parent = Class.new(ActiveRecord::Base) do
            include Apartment::Model
          end
          stub_const('PinnedParentBypass', parent)
          parent.pin_tenant

          child = Class.new(parent)
          stub_const('PinnedChildBypass', child)

          Apartment::Current.tenant = 'acme'
          expect(child.connection_pool).to(equal(default_pool))
        end
      end

      context 'when shared_pinned_connection? is true (shared pool)' do
        before do
          allow(mock_adapter).to(receive(:shared_pinned_connection?).and_return(true))
        end

        it 'returns the tenant pool for a pinned model (transactional integrity)' do
          pinned_class = Class.new(ActiveRecord::Base) do
            include Apartment::Model
          end
          stub_const('PinnedSharedModel', pinned_class)
          pinned_class.pin_tenant

          Apartment::Current.tenant = 'acme'
          expect(pinned_class.connection_pool).not_to(equal(default_pool))
        end

        it 'returns the tenant pool for STI subclass of a pinned model' do
          parent = Class.new(ActiveRecord::Base) do
            include Apartment::Model
          end
          stub_const('PinnedSharedParent', parent)
          parent.pin_tenant

          child = Class.new(parent)
          stub_const('PinnedSharedChild', child)

          Apartment::Current.tenant = 'acme'
          expect(child.connection_pool).not_to(equal(default_pool))
        end
      end

      it 'does not bypass for ActiveRecord::Base itself' do
        allow(mock_adapter).to(receive(:shared_pinned_connection?).and_return(false))
        Apartment::Current.tenant = 'acme'
        tenant_pool = ActiveRecord::Base.connection_pool
        expect(tenant_pool).not_to(equal(default_pool))
      end

      it 'does not bypass for an unpinned AR::Base subclass' do
        allow(mock_adapter).to(receive(:shared_pinned_connection?).and_return(false))
        unpinned = Class.new(ActiveRecord::Base)
        stub_const('UnpinnedWidget', unpinned)

        Apartment::Current.tenant = 'acme'
        expect(unpinned.connection_pool).not_to(equal(default_pool))
      end
    end

    context 'pinned model inside Tenant.each' do
      before do
        require_relative('../../../lib/apartment/concerns/model')
      end

      context 'when shared_pinned_connection? is false (separate pool)' do
        before do
          allow(mock_adapter).to(receive(:shared_pinned_connection?).and_return(false))
        end

        it 'returns the default pool for a pinned model while iterating tenants' do
          pinned_class = Class.new(ActiveRecord::Base) do
            include Apartment::Model
          end
          stub_const('PinnedInsideEach', pinned_class)
          pinned_class.pin_tenant

          pools_during_each = []
          Apartment::Tenant.each(%w[acme widgets]) do |_tenant|
            pools_during_each << pinned_class.connection_pool
          end

          expect(pools_during_each).to(all(equal(default_pool)))
        end
      end

      context 'when shared_pinned_connection? is true (shared pool)' do
        before do
          allow(mock_adapter).to(receive(:shared_pinned_connection?).and_return(true))
        end

        it 'returns the tenant pool for a pinned model while iterating tenants' do
          pinned_class = Class.new(ActiveRecord::Base) do
            include Apartment::Model
          end
          stub_const('PinnedSharedEach', pinned_class)
          pinned_class.pin_tenant

          pools_during_each = []
          Apartment::Tenant.each(%w[acme widgets]) do |_tenant|
            pools_during_each << pinned_class.connection_pool
          end

          pools_during_each.each do |pool|
            expect(pool).not_to(equal(default_pool))
          end
          expect(pools_during_each[0]).not_to(equal(pools_during_each[1]))
        end
      end

      it 'routes unpinned models to tenant pools while iterating' do
        unpinned = Class.new(ActiveRecord::Base)
        stub_const('UnpinnedInsideEach', unpinned)

        pools_during_each = []
        Apartment::Tenant.each(%w[acme widgets]) do |_tenant|
          pools_during_each << unpinned.connection_pool
        end

        pools_during_each.each do |pool|
          expect(pool).not_to(equal(default_pool))
        end
        expect(pools_during_each[0]).not_to(equal(pools_during_each[1]))
      end
    end

    context 'custom shard_key_prefix' do
      before do
        Apartment.configure do |config|
          config.tenant_strategy = :schema
          config.tenants_provider = -> { %w[acme] }
          config.default_tenant = 'public'
          config.shard_key_prefix = 'myapp'
          config.check_pending_migrations = false
        end
        Apartment.adapter = mock_adapter
      end

      it 'uses the custom prefix for shard keys' do
        Apartment::Current.tenant = 'acme'
        ActiveRecord::Base.connection_pool

        role = ActiveRecord::Base.current_role
        registered = ActiveRecord::Base.connection_handler.retrieve_connection_pool(
          'ActiveRecord::Base',
          role: role,
          shard: :"myapp_acme:#{role}"
        )
        expect(registered).not_to(be_nil)
      end

      it 'does not register under the default prefix' do
        Apartment::Current.tenant = 'acme'
        ActiveRecord::Base.connection_pool

        role = ActiveRecord::Base.current_role
        registered = ActiveRecord::Base.connection_handler.retrieve_connection_pool(
          'ActiveRecord::Base',
          role: role,
          shard: :"apartment_acme:#{role}"
        )
        expect(registered).to(be_nil)
      end
    end
  end

  describe 'pinned_model? registry check' do
    before do
      require_relative('../../../lib/apartment/concerns/model')
    end

    it 'returns true for a pinned model' do
      pinned_class = Class.new(ActiveRecord::Base) do
        include Apartment::Model
      end
      stub_const('PinnedGlobal', pinned_class)
      pinned_class.pin_tenant

      expect(Apartment.pinned_model?(PinnedGlobal)).to(be(true))
    end

    it 'returns true for STI subclass of a pinned model' do
      parent = Class.new(ActiveRecord::Base) do
        include Apartment::Model
      end
      stub_const('PinnedParentModel', parent)
      parent.pin_tenant

      child = Class.new(parent)
      stub_const('PinnedChildModel', child)

      expect(Apartment.pinned_model?(PinnedChildModel)).to(be(true))
    end

    it 'returns false for normal tenant models' do
      tenant_class = Class.new(ActiveRecord::Base)
      stub_const('TenantWidget', tenant_class)

      expect(Apartment.pinned_model?(TenantWidget)).to(be(false))
    end
  end
end
