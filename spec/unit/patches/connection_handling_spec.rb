# frozen_string_literal: true

require 'spec_helper'
require 'active_record'
require_relative '../../../lib/apartment/patches/connection_handling'

# This spec uses a real SQLite3 in-memory database.
# When the full suite runs, other specs may have loaded a stub ActiveRecord::Base
# without establish_connection. Skip this suite in that case — run it directly
# or via a gemfile that includes sqlite3 to get full coverage.
REAL_AR = ActiveRecord::Base.respond_to?(:establish_connection)

if REAL_AR
  # Establish the default SQLite3 connection once before any example runs.
  ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
  # Prepend the patch once; subsequent prepends of the same module are no-ops.
  ActiveRecord::Base.singleton_class.prepend(Apartment::Patches::ConnectionHandling)
end

RSpec.describe(Apartment::Patches::ConnectionHandling) do
  before { skip 'requires real ActiveRecord with SQLite3' unless REAL_AR }

  let(:mock_adapter) do
    double('AbstractAdapter',
           resolve_connection_config: { 'adapter' => 'sqlite3', 'database' => ':memory:' })
  end

  # Capture the default pool with no tenant set, for comparison in tests.
  let(:default_pool) do
    Apartment::Current.tenant = nil
    ActiveRecord::Base.connection_pool
  end

  before do
    Apartment.configure do |config|
      config.tenant_strategy = :schema
      config.tenants_provider = -> { %w[acme widgets] }
      config.default_tenant = 'public'
    end
    Apartment.adapter = mock_adapter
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

        registered = ActiveRecord::Base.connection_handler.retrieve_connection_pool(
          'ActiveRecord::Base',
          shard: :apartment_acme
        )
        expect(registered).not_to(be_nil)
      end

      it 'stores the correct adapter in db_config' do
        Apartment::Current.tenant = 'acme'
        pool = ActiveRecord::Base.connection_pool
        expect(pool.db_config.adapter).to(eq('sqlite3'))
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

        pool = ActiveRecord::Base.connection_handler.retrieve_connection_pool(
          'ActiveRecord::Base',
          role: ActiveRecord::Base.current_role,
          shard: :apartment_acme
        )
        expect(pool).not_to(be_nil)
        expect(pool).to(be_a(ActiveRecord::ConnectionAdapters::ConnectionPool))
      end
    end
  end
end
