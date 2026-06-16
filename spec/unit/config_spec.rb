# frozen_string_literal: true

require 'spec_helper'

RSpec.describe(Apartment::Config) do
  subject(:config) { described_class.new }

  describe 'defaults' do
    it { expect(config.tenant_strategy).to(be_nil) }
    it { expect(config.tenants_provider).to(be_nil) }
    it { expect(config.default_tenant).to(be_nil) }
    it { expect(config.excluded_models).to(eq([])) }
    it { expect(config.tenant_pool_size).to(be_nil) }
    it { expect(config.pool_idle_timeout).to(eq(300)) }
    it { expect(config.reaper_interval).to(be_nil) }
    it { expect(config.max_total_connections).to(be_nil) }
    it { expect(config.pool_overflow_policy).to(eq(:evict_idle)) }
    it { expect(config.seed_after_create).to(be(false)) }
    it { expect(config.seed_data_file).to(be_nil) }
    it { expect(config.parallel_migration_threads).to(eq(0)) }
    it { expect(config.environmentify_strategy).to(be_nil) }
    it { expect(config.elevator).to(be_nil) }
    it { expect(config.elevator_options).to(eq({})) }
    it { expect(config.tenant_not_found_handler).to(be_nil) }
    it { expect(config.active_record_log).to(be(false)) }
    it { expect(config.postgres_config).to(be_nil) }
    it { expect(config.mysql_config).to(be_nil) }
    it { expect(config.shard_key_prefix).to(eq('apartment')) }
    it { expect(config.force_separate_pinned_pool).to(be(false)) }
    it { expect(config.test_fixture_cleanup).to(be(true)) }
    it { expect(config.reap_in_test).to(be(false)) }
    it { expect(config.default_tenant_switch_allowed).to(be(true)) }
  end

  describe '#default_tenant_switch_allowed validation' do
    before do
      config.tenant_strategy = :schema
      config.tenants_provider = -> { [] }
    end

    it 'accepts true' do
      config.default_tenant_switch_allowed = true
      expect { config.validate! }.not_to(raise_error)
    end

    it 'accepts false' do
      config.default_tenant_switch_allowed = false
      expect { config.validate! }.not_to(raise_error)
    end

    it 'rejects non-boolean values' do
      config.default_tenant_switch_allowed = 'yes'
      expect { config.validate! }.to(raise_error(
                                       Apartment::ConfigurationError,
                                       /default_tenant_switch_allowed must be true or false/
                                     ))
    end

    it 'rejects nil' do
      config.default_tenant_switch_allowed = nil
      expect { config.validate! }.to(raise_error(
                                       Apartment::ConfigurationError,
                                       /default_tenant_switch_allowed must be true or false/
                                     ))
    end
  end

  describe '#tenant_strategy=' do
    it 'accepts valid strategies' do
      %i[schema database_name shard database_config].each do |strategy|
        expect { config.tenant_strategy = strategy }.not_to(raise_error)
      end
    end

    it 'rejects invalid strategies' do
      expect { config.tenant_strategy = :invalid }.to(raise_error(
                                                        Apartment::ConfigurationError, /Invalid tenant_strategy/
                                                      ))
    end
  end

  describe '#environmentify_strategy=' do
    it 'accepts nil, :prepend, :append' do
      [nil, :prepend, :append].each do |val|
        expect { config.environmentify_strategy = val }.not_to(raise_error)
      end
    end

    it 'accepts a callable' do
      expect { config.environmentify_strategy = ->(t) { "test_#{t}" } }.not_to(raise_error)
    end

    it 'rejects invalid values' do
      expect { config.environmentify_strategy = :bad }.to(
        raise_error(Apartment::ConfigurationError, /Invalid environmentify_strategy/)
      )
    end
  end

  describe '#configure_postgres' do
    it 'creates a PostgresqlConfig' do
      pg = config.configure_postgres do |pg|
        pg.persistent_schemas = ['shared']
      end

      expect(pg).to(be_a(Apartment::Configs::PostgresqlConfig))
      expect(pg.persistent_schemas).to(eq(['shared']))
      expect(config.postgres_config).to(eq(pg))
    end
  end

  describe '#configure_mysql' do
    it 'creates a MysqlConfig' do
      my = config.configure_mysql
      expect(my).to(be_a(Apartment::Configs::MysqlConfig))
      expect(config.mysql_config).to(eq(my))
    end
  end

  describe '#validate!' do
    it 'raises when tenant_strategy is missing' do
      expect { config.validate! }.to(raise_error(
                                       Apartment::ConfigurationError, /tenant_strategy is required/
                                     ))
    end

    it 'raises when tenants_provider is not callable' do
      config.tenant_strategy = :schema
      config.tenants_provider = 'not_callable'
      expect { config.validate! }.to(raise_error(
                                       Apartment::ConfigurationError, /tenants_provider must be a callable/
                                     ))
    end

    it 'raises when both postgres and mysql are configured' do
      config.tenant_strategy = :schema
      config.tenants_provider = -> { [] }
      config.configure_postgres
      config.configure_mysql
      expect { config.validate! }.to(raise_error(
                                       Apartment::ConfigurationError, /Cannot configure both/
                                     ))
    end

    it 'raises when tenants_provider is missing' do
      config.tenant_strategy = :schema
      expect { config.validate! }.to(raise_error(
                                       Apartment::ConfigurationError, /tenants_provider/
                                     ))
    end

    it 'raises when tenant_pool_size is not a positive integer' do
      config.tenant_strategy = :schema
      config.tenants_provider = -> { [] }
      config.tenant_pool_size = 0
      expect { config.validate! }.to(raise_error(Apartment::ConfigurationError, /tenant_pool_size/))
    end

    it 'allows tenant_pool_size to be nil (inherit the base pool size)' do
      config.tenant_strategy = :schema
      config.tenants_provider = -> { [] }
      config.tenant_pool_size = nil
      expect { config.validate! }.not_to(raise_error)
    end

    it 'allows tenant_pool_size to be a positive integer' do
      config.tenant_strategy = :schema
      config.tenants_provider = -> { [] }
      config.tenant_pool_size = 3
      expect { config.validate! }.not_to(raise_error)
    end

    it 'raises when pool_idle_timeout is not a positive number' do
      config.tenant_strategy = :schema
      config.tenants_provider = -> { [] }
      config.pool_idle_timeout = -1
      expect { config.validate! }.to(raise_error(Apartment::ConfigurationError, /pool_idle_timeout/))
    end

    it 'raises when max_total_connections is invalid' do
      config.tenant_strategy = :schema
      config.tenants_provider = -> { [] }
      config.max_total_connections = 0
      expect { config.validate! }.to(raise_error(Apartment::ConfigurationError, /max_total_connections/))
    end

    it 'raises when reaper_interval is not a positive number' do
      config.tenant_strategy = :schema
      config.tenants_provider = -> { [] }
      config.reaper_interval = 0
      expect { config.validate! }.to(raise_error(Apartment::ConfigurationError, /reaper_interval/))
    end

    it 'allows reaper_interval to be nil (defaults to pool_idle_timeout)' do
      config.tenant_strategy = :schema
      config.tenants_provider = -> { [] }
      config.reaper_interval = nil
      expect { config.validate! }.not_to(raise_error)
    end

    it 'raises when pool_overflow_policy is unknown' do
      config.tenant_strategy = :schema
      config.tenants_provider = -> { [] }
      config.pool_overflow_policy = :block
      expect { config.validate! }.to(raise_error(Apartment::ConfigurationError, /pool_overflow_policy/))
    end

    it 'accepts :raise as a pool_overflow_policy' do
      config.tenant_strategy = :schema
      config.tenants_provider = -> { [] }
      config.pool_overflow_policy = :raise
      expect { config.validate! }.not_to(raise_error)
    end

    it 'raises when reap_in_test is not a boolean' do
      config.tenant_strategy = :schema
      config.tenants_provider = -> { [] }
      config.reap_in_test = 'yes'
      expect { config.validate! }.to(raise_error(Apartment::ConfigurationError, /reap_in_test/))
    end

    it 'accepts reap_in_test = true' do
      config.tenant_strategy = :schema
      config.tenants_provider = -> { [] }
      config.reap_in_test = true
      expect { config.validate! }.not_to(raise_error)
    end

    it 'passes with valid minimal configuration' do
      config.tenant_strategy = :schema
      config.tenants_provider = -> { [] }
      expect { config.validate! }.not_to(raise_error)
    end

    context 'reaper_interval defaulting' do
      before do
        config.tenant_strategy = :schema
        config.tenants_provider = -> { [] }
      end

      it 'defaults reaper_interval to pool_idle_timeout when not set' do
        config.pool_idle_timeout = 120
        config.apply_defaults!
        expect(config.reaper_interval).to(eq(120))
      end

      it 'preserves an explicit reaper_interval distinct from pool_idle_timeout' do
        config.pool_idle_timeout = 300
        config.reaper_interval = 30
        config.apply_defaults!
        expect(config.reaper_interval).to(eq(30))
        expect(config.pool_idle_timeout).to(eq(300))
      end
    end

    context 'default_tenant auto-defaulting' do
      before do
        config.tenants_provider = -> { [] }
      end

      it 'defaults to public for schema strategy when not set' do
        config.tenant_strategy = :schema
        config.apply_defaults!
        expect(config.default_tenant).to(eq('public'))
      end

      it 'preserves explicit default_tenant for schema strategy' do
        config.tenant_strategy = :schema
        config.default_tenant = 'custom'
        config.apply_defaults!
        expect(config.default_tenant).to(eq('custom'))
      end

      it 'does not default for database_name strategy' do
        config.tenant_strategy = :database_name
        config.apply_defaults!
        expect(config.default_tenant).to(be_nil)
      end

      it 'is not applied by validate!; validate! stays read-only' do
        config.tenant_strategy = :schema
        config.validate!
        expect(config.default_tenant).to(be_nil)
      end

      it 'rejects an empty string' do
        config.tenant_strategy = :schema
        config.default_tenant = ''
        expect { config.validate! }.to(raise_error(Apartment::ConfigurationError, /empty string/))
      end

      it 'rejects a whitespace-only string' do
        config.tenant_strategy = :schema
        config.default_tenant = '  '
        expect { config.validate! }.to(raise_error(Apartment::ConfigurationError, /empty string/))
      end
    end

    context 'migration_role validation' do
      before do
        config.tenant_strategy = :schema
        config.tenants_provider = -> { [] }
      end

      it 'rejects a non-symbol value' do
        config.migration_role = 'db_manager'
        expect { config.validate! }.to(raise_error(Apartment::ConfigurationError, /migration_role/))
      end

      it 'accepts nil' do
        config.migration_role = nil
        expect { config.validate! }.not_to(raise_error)
      end

      it 'accepts a symbol' do
        config.migration_role = :db_manager
        expect { config.validate! }.not_to(raise_error)
      end
    end

    context 'app_role validation' do
      before do
        config.tenant_strategy = :schema
        config.tenants_provider = -> { [] }
      end

      it 'rejects a non-string non-callable value' do
        config.app_role = 123
        expect { config.validate! }.to(raise_error(Apartment::ConfigurationError, /app_role/))
      end

      it 'accepts nil' do
        config.app_role = nil
        expect { config.validate! }.not_to(raise_error)
      end

      it 'accepts a string' do
        config.app_role = 'app_user'
        expect { config.validate! }.not_to(raise_error)
      end

      it 'accepts a callable' do
        config.app_role = -> { 'dynamic_role' }
        expect { config.validate! }.not_to(raise_error)
      end
    end

    context 'schema_cache_per_tenant validation' do
      before do
        config.tenant_strategy = :schema
        config.tenants_provider = -> { [] }
      end

      it 'rejects a non-boolean value' do
        config.schema_cache_per_tenant = 'yes'
        expect { config.validate! }.to(raise_error(Apartment::ConfigurationError, /schema_cache_per_tenant/))
      end

      it 'accepts true' do
        config.schema_cache_per_tenant = true
        expect { config.validate! }.not_to(raise_error)
      end

      it 'accepts false' do
        config.schema_cache_per_tenant = false
        expect { config.validate! }.not_to(raise_error)
      end
    end

    context 'check_pending_migrations validation' do
      before do
        config.tenant_strategy = :schema
        config.tenants_provider = -> { [] }
      end

      it 'rejects a non-boolean value' do
        config.check_pending_migrations = 1
        expect { config.validate! }.to(raise_error(Apartment::ConfigurationError, /check_pending_migrations/))
      end

      it 'accepts true' do
        config.check_pending_migrations = true
        expect { config.validate! }.not_to(raise_error)
      end

      it 'accepts false' do
        config.check_pending_migrations = false
        expect { config.validate! }.not_to(raise_error)
      end
    end

    describe '#force_separate_pinned_pool' do
      it 'accepts true' do
        config.tenant_strategy = :schema
        config.tenants_provider = -> { [] }
        config.force_separate_pinned_pool = true
        expect { config.validate! }.not_to(raise_error)
      end

      it 'accepts false' do
        config.tenant_strategy = :schema
        config.tenants_provider = -> { [] }
        config.force_separate_pinned_pool = false
        expect { config.validate! }.not_to(raise_error)
      end

      it 'rejects non-boolean values' do
        config.tenant_strategy = :schema
        config.tenants_provider = -> { [] }
        config.force_separate_pinned_pool = 'yes'
        expect { config.validate! }.to(raise_error(Apartment::ConfigurationError, /force_separate_pinned_pool/))
      end
    end
  end

  describe 'persistent_schemas validation' do
    before do
      config.tenant_strategy = :schema
      config.tenants_provider = -> { [] }
    end

    it 'accepts valid PostgreSQL identifiers' do
      config.configure_postgres { |pg| pg.persistent_schemas = %w[shared ext] }
      expect { config.validate! }.not_to(raise_error)
    end

    it 'accepts empty persistent_schemas' do
      config.configure_postgres { |pg| pg.persistent_schemas = [] }
      expect { config.validate! }.not_to(raise_error)
    end

    it 'rejects schemas exceeding 63 characters' do
      config.configure_postgres { |pg| pg.persistent_schemas = ['a' * 64] }
      expect { config.validate! }.to(raise_error(Apartment::ConfigurationError, /persistent_schema.*too long/i))
    end

    it 'rejects schemas with invalid characters' do
      config.configure_postgres { |pg| pg.persistent_schemas = ['invalid schema!'] }
      expect { config.validate! }.to(raise_error(Apartment::ConfigurationError, /persistent_schema/))
    end

    it 'rejects schemas starting with pg_ prefix' do
      config.configure_postgres { |pg| pg.persistent_schemas = ['pg_temp'] }
      expect { config.validate! }.to(raise_error(Apartment::ConfigurationError, /persistent_schema.*pg_/))
    end

    it 'skips validation when postgres_config is nil' do
      expect { config.validate! }.not_to(raise_error)
    end
  end

  describe '#shard_key_prefix validation' do
    before do
      config.tenant_strategy = :schema
      config.tenants_provider = -> { [] }
    end

    it 'passes with the default value' do
      expect { config.validate! }.not_to(raise_error)
    end

    it 'passes with a custom valid prefix' do
      config.shard_key_prefix = 'myapp_tenant'
      expect { config.validate! }.not_to(raise_error)
    end

    it 'raises ConfigurationError for empty string' do
      config.shard_key_prefix = ''
      expect { config.validate! }.to(raise_error(Apartment::ConfigurationError, /shard_key_prefix/))
    end

    it 'raises ConfigurationError for string starting with a number' do
      config.shard_key_prefix = '1bad'
      expect { config.validate! }.to(raise_error(Apartment::ConfigurationError, /shard_key_prefix/))
    end

    it 'raises ConfigurationError for string with special characters' do
      config.shard_key_prefix = 'my-prefix'
      expect { config.validate! }.to(raise_error(Apartment::ConfigurationError, /shard_key_prefix/))
    end

    it 'raises ConfigurationError for non-string value' do
      config.shard_key_prefix = :symbol
      expect { config.validate! }.to(raise_error(Apartment::ConfigurationError, /shard_key_prefix/))
    end
  end

  describe 'schema_load_strategy' do
    it 'defaults to nil (opt-in schema loading)' do
      config = described_class.new
      expect(config.schema_load_strategy).to(be_nil)
    end

    it 'accepts :schema_rb' do
      config = described_class.new
      config.schema_load_strategy = :schema_rb
      expect(config.schema_load_strategy).to(eq(:schema_rb))
    end

    it 'accepts :sql' do
      config = described_class.new
      config.schema_load_strategy = :sql
      expect(config.schema_load_strategy).to(eq(:sql))
    end

    it 'accepts nil' do
      config = described_class.new
      config.schema_load_strategy = nil
      expect(config.schema_load_strategy).to(be_nil)
    end

    it 'rejects invalid values during validation' do
      expect do
        Apartment.configure do |c|
          c.tenant_strategy = :schema
          c.tenants_provider = -> { [] }
          c.schema_load_strategy = :invalid
        end
      end.to(raise_error(Apartment::ConfigurationError, /Invalid schema_load_strategy/))
    end
  end

  describe 'migration_role' do
    it 'defaults to nil' do
      expect(config.migration_role).to(be_nil)
    end

    it 'accepts nil' do
      config.migration_role = nil
      expect(config.migration_role).to(be_nil)
    end

    it 'accepts a symbol' do
      config.migration_role = :db_manager
      expect(config.migration_role).to(eq(:db_manager))
    end
  end

  describe 'app_role' do
    it 'defaults to nil' do
      expect(config.app_role).to(be_nil)
    end

    it 'accepts nil' do
      config.app_role = nil
      expect(config.app_role).to(be_nil)
    end

    it 'accepts a string' do
      config.app_role = 'app_user'
      expect(config.app_role).to(eq('app_user'))
    end

    it 'accepts a callable' do
      callable = -> { 'dynamic_role' }
      config.app_role = callable
      expect(config.app_role).to(eq(callable))
    end
  end

  describe 'schema_cache_per_tenant' do
    it 'defaults to false' do
      expect(config.schema_cache_per_tenant).to(be(false))
    end

    it 'accepts true' do
      config.schema_cache_per_tenant = true
      expect(config.schema_cache_per_tenant).to(be(true))
    end

    it 'accepts false' do
      config.schema_cache_per_tenant = false
      expect(config.schema_cache_per_tenant).to(be(false))
    end
  end

  describe 'check_pending_migrations' do
    it 'defaults to true' do
      expect(config.check_pending_migrations).to(be(true))
    end

    it 'accepts true' do
      config.check_pending_migrations = true
      expect(config.check_pending_migrations).to(be(true))
    end

    it 'accepts false' do
      config.check_pending_migrations = false
      expect(config.check_pending_migrations).to(be(false))
    end
  end

  describe 'schema_file' do
    it 'defaults to nil' do
      config = described_class.new
      expect(config.schema_file).to(be_nil)
    end

    it 'accepts a string path' do
      config = described_class.new
      config.schema_file = '/path/to/schema.rb'
      expect(config.schema_file).to(eq('/path/to/schema.rb'))
    end
  end

  describe '#rails_env_name' do
    around do |example|
      saved_rails_env = ENV.fetch('RAILS_ENV', nil)
      saved_rack_env = ENV.fetch('RACK_ENV', nil)
      example.run
      ENV['RAILS_ENV'] = saved_rails_env
      ENV['RACK_ENV'] = saved_rack_env
    end

    it 'returns Rails.env when Rails is defined' do
      stub_const('Rails', double(env: 'test'))
      expect(config.rails_env_name).to(eq('test'))
    end

    it 'falls back to RAILS_ENV env var' do
      hide_const('Rails')
      ENV['RAILS_ENV'] = 'staging'
      ENV.delete('RACK_ENV')
      expect(config.rails_env_name).to(eq('staging'))
    end

    it 'falls back to RACK_ENV env var' do
      hide_const('Rails')
      ENV.delete('RAILS_ENV')
      ENV['RACK_ENV'] = 'production'
      expect(config.rails_env_name).to(eq('production'))
    end

    it "defaults to 'default_env' when nothing is set" do
      hide_const('Rails')
      ENV.delete('RAILS_ENV')
      ENV.delete('RACK_ENV')
      expect(config.rails_env_name).to(eq('default_env'))
    end
  end

  describe '#tenant_validator' do
    it 'defaults to nil' do
      expect(described_class.new.tenant_validator).to(be_nil)
    end

    it 'accepts false (validation disabled)' do
      config = described_class.new
      config.tenant_strategy = :schema
      config.tenants_provider = -> { [] }
      config.tenant_validator = false
      expect { config.validate! }.not_to(raise_error)
    end

    it 'accepts a callable' do
      config = described_class.new
      config.tenant_strategy = :schema
      config.tenants_provider = -> { [] }
      config.tenant_validator = ->(name) { name == 'acme' }
      expect { config.validate! }.not_to(raise_error)
    end

    it 'rejects a non-callable, non-false value' do
      config = described_class.new
      config.tenant_strategy = :schema
      config.tenants_provider = -> { [] }
      config.tenant_validator = 'nope'
      expect { config.validate! }
        .to(raise_error(Apartment::ConfigurationError, /tenant_validator/))
    end
  end

  describe '#tenant_not_found_handler' do
    it 'rejects a non-callable value' do
      config = described_class.new
      config.tenant_strategy = :schema
      config.tenants_provider = -> { [] }
      config.tenant_not_found_handler = 'nope'
      expect { config.validate! }
        .to(raise_error(Apartment::ConfigurationError, /tenant_not_found_handler/))
    end
  end
end

RSpec.describe('Apartment.configure') do
  it 'yields a Config instance and stores it' do
    Apartment.configure do |config|
      config.tenant_strategy = :schema
      config.tenants_provider = -> { [] }
      config.default_tenant = 'public'
    end

    expect(Apartment.config).to(be_a(Apartment::Config))
    expect(Apartment.config.tenant_strategy).to(eq(:schema))
    expect(Apartment.config.default_tenant).to(eq('public'))
  end

  it 'validates the configuration' do
    expect do
      Apartment.configure { |c| } # no strategy set
    end.to(raise_error(Apartment::ConfigurationError))
  end

  it 'raises without a block' do
    expect { Apartment.configure }.to(raise_error(Apartment::ConfigurationError, /requires a block/))
  end

  it 'freezes the config after validation' do
    Apartment.configure do |config|
      config.tenant_strategy = :schema
      config.tenants_provider = -> { [] }
    end

    expect(Apartment.config).to(be_frozen)
    expect(Apartment.config.excluded_models).to(be_frozen)
    expect { Apartment.config.default_tenant = 'x' }.to(raise_error(FrozenError))
  end

  it 'preserves previous config when reconfigure fails' do
    Apartment.configure do |config|
      config.tenant_strategy = :schema
      config.tenants_provider = -> { [] }
      config.default_tenant = 'original'
    end

    expect do
      Apartment.configure { |c| } # no strategy — will fail validation
    end.to(raise_error(Apartment::ConfigurationError))

    expect(Apartment.config.default_tenant).to(eq('original'))
  end
end

RSpec.describe('Apartment.clear_config') do
  it 'resets config and pool_manager to nil' do
    Apartment.configure do |c|
      c.tenant_strategy = :schema
      c.tenants_provider = -> { [] }
    end
    Apartment.clear_config

    expect(Apartment.config).to(be_nil)
    expect(Apartment.pool_manager).to(be_nil)
  end
end
