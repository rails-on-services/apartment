# frozen_string_literal: true

require 'spec_helper'

# This spec requires real ActiveRecord + sqlite3 gem (not the stub in apartment_spec.rb).
# Run via any sqlite3 appraisal, e.g.: bundle exec appraisal rails-8.1-sqlite3 rspec spec/unit/patches/
# Skips gracefully when sqlite3 is not available or when the AR stub from
# apartment_spec.rb loaded first (randomized suite order).
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
    warn '[connection_handling_spec] Skipping: AR stub loaded (no establish_connection)'
    false
  end
rescue LoadError => e
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
    double('AbstractAdapter',
           validated_connection_config: { 'adapter' => 'sqlite3', 'database' => ':memory:' })
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

    context 'when tenant equals the default tenant' do
      it 'returns the default pool' do
        Apartment::Current.tenant = 'public'
        expect(ActiveRecord::Base.connection_pool).to(equal(default_pool))
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

      it 'returns the default pool for a pinned AR::Base subclass when tenant is set' do
        pinned_class = Class.new(ActiveRecord::Base) do
          include Apartment::Model
        end
        stub_const('PinnedBypassModel', pinned_class)
        pinned_class.pin_tenant

        Apartment::Current.tenant = 'acme'
        # Pinned class must use super (default pool), not the tenant pool
        expect(pinned_class.connection_pool).to(equal(default_pool))
      end

      it 'does not bypass for ActiveRecord::Base itself' do
        Apartment::Current.tenant = 'acme'
        tenant_pool = ActiveRecord::Base.connection_pool
        expect(tenant_pool).not_to(equal(default_pool))
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

      it 'does not bypass for an unpinned AR::Base subclass' do
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
