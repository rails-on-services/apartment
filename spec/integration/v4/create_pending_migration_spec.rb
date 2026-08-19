# frozen_string_literal: true

require 'spec_helper'
require_relative 'support'

# Creating a tenant must not trip the pending-migration check.
#
# `create` switches into the new tenant whenever it has to load a schema or run
# seeds, and that switch resolves a pool, which is where
# ConnectionHandling#check_pending_migrations? runs. A container created moments
# ago has of course not run any migration, so the check fires against the very
# thing being built and `create` raises PendingMigrationError instead of
# finishing. The Migrator does not hit this because it sets
# `Apartment::Current.migrating` around its own switches; creation never did.
#
# The check only runs when `check_pending_migrations` is true (the default) and
# `Rails.env.local?`, so this reproduces in development and test — where
# creating a tenant is most common — and not in production.
RSpec.describe('Tenant create with the pending-migration check enabled', :integration,
               skip: (V4_INTEGRATION_AVAILABLE && V4IntegrationHelper.postgresql? ? false : 'requires PostgreSQL')) do
  include V4IntegrationHelper

  let(:tmp_dir) { Dir.mktmpdir('apartment_create_pending') }
  let(:migration_dir) { Dir.mktmpdir('apartment_create_pending_migrations') }
  let(:created_tenants) { [] }

  before do
    V4IntegrationHelper.ensure_test_database!
    config = V4IntegrationHelper.establish_default_connection!(tmp_dir: tmp_dir)

    Apartment.configure do |c|
      c.tenant_strategy = :schema
      c.tenants_provider = -> { [] }
      c.default_tenant = 'public'
      c.check_pending_migrations = true
      c.seed_after_create = true
      c.seed_data_file = File.join(tmp_dir, 'seeds.rb')
    end

    # Seeding is one of the two create-time switches (schema import is the other).
    # The seed file has to touch the database: Tenant.switch only sets the tenant,
    # and the pool — where the check runs — is resolved by the first query.
    File.write(File.join(tmp_dir, 'seeds.rb'), "ActiveRecord::Base.connection.select_value('SELECT 1')\n")

    # An unrun migration, so needs_migration? has something to be true about.
    # [7.2] is the floor of the supported matrix.
    File.write(File.join(migration_dir, '20260401000001_create_pending_probe.rb'), <<~RUBY)
      class CreatePendingProbe < ActiveRecord::Migration[7.2]
        def change
          create_table(:pending_probes) { |t| t.string(:name) }
        end
      end
    RUBY

    @original_migrations_paths = ActiveRecord::Migrator.migrations_paths
    ActiveRecord::Migrator.migrations_paths = [migration_dir]

    # spec/support/rails_stub.rb returns a StringInquirer, whose #local? asks whether
    # the env is literally named "local" — so Rails.env.local? is false and the check
    # is inert for the whole suite. EnvironmentInquirer is what a real Rails app has,
    # and its #local? is true for development and test.
    allow(Rails).to(receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new('test')))

    Apartment.adapter = V4IntegrationHelper.build_adapter(config)
    Apartment.activate!
  end

  after do
    ActiveRecord::Migrator.migrations_paths = @original_migrations_paths
    V4IntegrationHelper.cleanup_tenants!(created_tenants, Apartment.adapter)
    Apartment.clear_config
    Apartment::Current.reset
    FileUtils.rm_rf(migration_dir)
  end

  it 'creates the tenant rather than raising against the container it just built' do
    expect { Apartment.adapter.create('pending_check_tenant') }.not_to(raise_error)
    created_tenants << 'pending_check_tenant'
  end

  it 'leaves the check armed for a tenant it did not create' do
    Apartment.adapter.create('pending_check_tenant')
    created_tenants << 'pending_check_tenant'

    # Created behind Apartment's back, so its pool is still cold and the check has
    # not been suppressed for it. Proves the suppression is scoped to create rather
    # than disarming the check for the rest of the process.
    ActiveRecord::Base.connection.execute('CREATE SCHEMA "pending_check_outsider"')
    created_tenants << 'pending_check_outsider'

    expect do
      Apartment::Tenant.switch('pending_check_outsider') do
        ActiveRecord::Base.connection.select_value('SELECT 1')
      end
    end.to(raise_error(Apartment::PendingMigrationError))
  end

  # The pool create leaves behind was built under suppression, so it escapes the
  # check for as long as it stays cached. That is deliberate: the check is a
  # development convenience, and a tenant this process created moments ago is the
  # case where the warning is least useful. Forcing pool churn to re-arm a dev-only
  # warning would be the worse trade. The next COLD pool for the tenant is checked
  # normally, which the example above covers for an unsuppressed tenant.
  it 'does not re-check the warm pool it created' do
    Apartment.adapter.create('pending_check_tenant')
    created_tenants << 'pending_check_tenant'

    expect do
      Apartment::Tenant.switch('pending_check_tenant') do
        ActiveRecord::Base.connection.select_value('SELECT 1')
      end
    end.not_to(raise_error)
  end
end
