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
    end
    Apartment.adapter = mock_adapter
  end

  let(:mock_adapter) do
    double('AbstractAdapter',
           resolve_connection_config: { 'adapter' => 'sqlite3', 'database' => ':memory:' })
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

        shard_key = :"#{Apartment.config.shard_key_prefix}_acme"
        registered = ActiveRecord::Base.connection_handler.retrieve_connection_pool(
          'ActiveRecord::Base',
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

        # Verify they exist
        %w[acme widgets].each do |t|
          expect(ActiveRecord::Base.connection_handler.retrieve_connection_pool(
                   'ActiveRecord::Base', shard: :"#{prefix}_#{t}"
                 )).not_to(be_nil)
        end

        # Deregister all
        Apartment.send(:deregister_all_tenant_pools)

        # Verify they're gone
        %w[acme widgets].each do |t|
          expect(ActiveRecord::Base.connection_handler.retrieve_connection_pool(
                   'ActiveRecord::Base', shard: :"#{prefix}_#{t}"
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
        expect(Apartment.pool_manager.tracked?('acme')).to(be(true))
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
               resolve_connection_config: { 'adapter' => 'sqlite3', 'database' => ':memory:' })
      end

      before do
        Apartment.configure do |config|
          config.tenant_strategy = :schema
          config.tenants_provider = -> { ['my-tenant'] }
          config.default_tenant = 'public'
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
        expect(Apartment.pool_manager.tracked?('my-tenant')).to(be(true))
      end
    end

    context 'role interaction' do
      it 'registers pool under the default role and namespaced shard key' do
        Apartment::Current.tenant = 'acme'
        ActiveRecord::Base.connection_pool

        shard_key = :"#{Apartment.config.shard_key_prefix}_acme"
        pool = ActiveRecord::Base.connection_handler.retrieve_connection_pool(
          'ActiveRecord::Base',
          role: ActiveRecord::Base.current_role,
          shard: shard_key
        )
        expect(pool).not_to(be_nil)
        expect(pool).to(be_a(ActiveRecord::ConnectionAdapters::ConnectionPool))
      end
    end

    context 'custom shard_key_prefix' do
      before do
        Apartment.configure do |config|
          config.tenant_strategy = :schema
          config.tenants_provider = -> { %w[acme] }
          config.default_tenant = 'public'
          config.shard_key_prefix = 'myapp'
        end
        Apartment.adapter = mock_adapter
      end

      it 'uses the custom prefix for shard keys' do
        Apartment::Current.tenant = 'acme'
        ActiveRecord::Base.connection_pool

        registered = ActiveRecord::Base.connection_handler.retrieve_connection_pool(
          'ActiveRecord::Base',
          role: ActiveRecord::Base.current_role,
          shard: :myapp_acme
        )
        expect(registered).not_to(be_nil)
      end

      it 'does not register under the default prefix' do
        Apartment::Current.tenant = 'acme'
        ActiveRecord::Base.connection_pool

        registered = ActiveRecord::Base.connection_handler.retrieve_connection_pool(
          'ActiveRecord::Base',
          role: ActiveRecord::Base.current_role,
          shard: :apartment_acme
        )
        expect(registered).to(be_nil)
      end
    end
  end
end
