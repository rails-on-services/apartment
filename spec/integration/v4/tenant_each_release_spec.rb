# frozen_string_literal: true

require 'spec_helper'
require_relative 'support'

# Tenant.each(release_connection: true) returns the leased connection after each
# tenant so a long fan-out doesn't hold one warm connection per visited tenant —
# the finished tenant's pool becomes reap-eligible mid-run. See component B of
# docs/designs/v4-pool-adopter-ergonomics.md.
#
# The effect is only observable for blocks that leave a connection checked out
# for the thread (raw `ActiveRecord::Base.connection` use, an open transaction, a
# long-held connection). Modern query methods (create!, where, ...) check the
# connection back in themselves on Rails 7.2+, so these specs use the raw
# `connection.execute` pattern to exercise the sticky lease release_connection
# targets.
RSpec.describe('v4 Tenant.each(release_connection:)', :integration,
               skip: (V4_INTEGRATION_AVAILABLE ? false : 'requires ActiveRecord + database gem')) do
  include V4IntegrationHelper

  context 'releasing connections between iterations',
          skip: (if V4IntegrationHelper.sqlite?
                   'SQLite pool-per-tenant less meaningful with single-writer lock'
                 else
                   false
                 end) do
    let(:tmp_dir) { Dir.mktmpdir('apartment_each_release') }
    let(:tenants) { Array.new(4) { |i| "each_release_#{i}" } }

    before do
      V4IntegrationHelper.ensure_test_database!
      config = V4IntegrationHelper.establish_default_connection!(tmp_dir: tmp_dir)
      V4IntegrationHelper.create_test_table!

      Apartment.configure do |c|
        c.tenant_strategy = V4IntegrationHelper.tenant_strategy
        c.tenants_provider = -> { tenants }
        c.default_tenant = V4IntegrationHelper.default_tenant
        c.check_pending_migrations = false
      end

      Apartment.adapter = V4IntegrationHelper.build_adapter(config)
      Apartment.activate!

      tenants.each { |t| Apartment.adapter.create(t) }
    end

    after do
      ActiveRecord::Base.connection_handler.clear_active_connections!(:all)
      V4IntegrationHelper.cleanup_tenants!(tenants, Apartment.adapter)
      Apartment.clear_config
      Apartment::Current.reset
      FileUtils.rm_rf(tmp_dir)
    end

    # Pools (one per "tenant:role") with at least one leased connection — i.e.
    # not yet reap-eligible.
    def leased_pool_count
      role = ActiveRecord::Base.current_role
      tenants.count do |t|
        pool = Apartment.pool_manager.peek("#{t}:#{role}")
        pool&.connections&.any?(&:in_use?)
      end
    end

    it 'leaves no leased connection on any visited pool' do
      # Clean slate, then a fan-out whose block holds a connection.
      ActiveRecord::Base.connection_handler.clear_active_connections!(:all)

      Apartment::Tenant.each(release_connection: true) do
        ActiveRecord::Base.connection.execute('SELECT 1')
      end

      expect(leased_pool_count).to(eq(0))
    end

    it 'leaves a leased connection per tenant without release_connection (contrast)' do
      ActiveRecord::Base.connection_handler.clear_active_connections!(:all)

      Apartment::Tenant.each do
        ActiveRecord::Base.connection.execute('SELECT 1')
      end

      expect(leased_pool_count).to(eq(tenants.size))
    end
  end
end
