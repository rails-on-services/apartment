# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../lib/apartment/adapters/abstract_adapter'

# Concrete test subclass that implements protected abstract methods.
class TestAdapter < Apartment::Adapters::AbstractAdapter
  attr_reader :created_tenants, :dropped_tenants

  def initialize(config)
    super
    @created_tenants = []
    @dropped_tenants = []
  end

  def resolve_connection_config(tenant)
    { adapter: 'postgresql', database: tenant }
  end

  protected

  def create_tenant(tenant)
    @created_tenants << tenant
  end

  def drop_tenant(tenant)
    @dropped_tenants << tenant
  end
end

# Minimal Rails stub for environmentify tests.
module Rails
  def self.env
    'test'
  end
end unless defined?(Rails)

# Minimal ActiveRecord stub for migrate tests.
unless defined?(ActiveRecord::Base)
  module ActiveRecord
    class Base
      def self.connection_pool
        raise 'stub: override with allow in tests'
      end
    end
  end
end

RSpec.describe Apartment::Adapters::AbstractAdapter do
  let(:config) { instance_double(Apartment::Config) }
  let(:adapter) { TestAdapter.new(config) }

  before do
    Apartment.configure do |c|
      c.tenant_strategy = :schema
      c.tenants_provider = -> { %w[t1 t2] }
      c.default_tenant = 'public'
    end
  end

  describe '#initialize' do
    it 'stores the config' do
      expect(adapter.config).to eq(config)
    end
  end

  describe '#resolve_connection_config' do
    it 'raises NotImplementedError on the abstract class' do
      abstract = described_class.new(config)
      expect { abstract.resolve_connection_config('t1') }.to raise_error(NotImplementedError)
    end

    it 'returns a config hash in the concrete subclass' do
      expect(adapter.resolve_connection_config('t1')).to eq(adapter: 'postgresql', database: 't1')
    end
  end

  describe '#create' do
    it 'delegates to create_tenant' do
      allow(Apartment::Instrumentation).to receive(:instrument)
      adapter.create('acme')
      expect(adapter.created_tenants).to eq(['acme'])
    end

    it 'instruments the create event' do
      expect(Apartment::Instrumentation).to receive(:instrument).with(:create, tenant: 'acme')
      adapter.create('acme')
    end

    it 'runs :create callbacks around the operation' do
      callback_log = []

      TestAdapter.set_callback(:create, :before) { callback_log << :before }
      TestAdapter.set_callback(:create, :after) { callback_log << :after }

      allow(Apartment::Instrumentation).to receive(:instrument)
      adapter.create('acme')

      expect(callback_log).to eq(%i[before after])
    ensure
      TestAdapter.reset_callbacks(:create)
    end
  end

  describe '#drop' do
    let(:pool_manager) { Apartment.pool_manager }

    it 'delegates to drop_tenant' do
      allow(Apartment::Instrumentation).to receive(:instrument)
      adapter.drop('acme')
      expect(adapter.dropped_tenants).to eq(['acme'])
    end

    it 'removes the pool from PoolManager' do
      allow(Apartment::Instrumentation).to receive(:instrument)
      expect(pool_manager).to receive(:remove).with('acme').and_return(nil)
      adapter.drop('acme')
    end

    it 'disconnects the pool if it responds to disconnect!' do
      mock_pool = double('Pool', disconnect!: true)
      allow(pool_manager).to receive(:remove).and_return(mock_pool)
      allow(Apartment::Instrumentation).to receive(:instrument)

      expect(mock_pool).to receive(:disconnect!)
      adapter.drop('acme')
    end

    it 'does not call disconnect! if pool does not respond to it' do
      mock_pool = double('Pool')
      allow(pool_manager).to receive(:remove).and_return(mock_pool)
      allow(Apartment::Instrumentation).to receive(:instrument)

      # Should not raise
      adapter.drop('acme')
    end

    it 'instruments the drop event' do
      allow(pool_manager).to receive(:remove).and_return(nil)
      expect(Apartment::Instrumentation).to receive(:instrument).with(:drop, tenant: 'acme')
      adapter.drop('acme')
    end
  end

  describe '#migrate' do
    it 'switches tenant and runs migrations' do
      migration_context = double('MigrationContext')
      connection_pool = double('ConnectionPool', migration_context: migration_context)

      allow(ActiveRecord::Base).to receive(:connection_pool).and_return(connection_pool)
      expect(migration_context).to receive(:migrate).with(nil)

      adapter.migrate('acme')
    end

    it 'passes version to migrate' do
      migration_context = double('MigrationContext')
      connection_pool = double('ConnectionPool', migration_context: migration_context)

      allow(ActiveRecord::Base).to receive(:connection_pool).and_return(connection_pool)
      expect(migration_context).to receive(:migrate).with(20_260_101_000_000)

      adapter.migrate('acme', 20_260_101_000_000)
    end

    it 'restores tenant context after migration' do
      migration_context = double('MigrationContext', migrate: true)
      connection_pool = double('ConnectionPool', migration_context: migration_context)
      allow(ActiveRecord::Base).to receive(:connection_pool).and_return(connection_pool)

      Apartment::Current.tenant = 'original'
      adapter.migrate('acme')
      expect(Apartment::Current.tenant).to eq('original')
    end
  end

  describe '#seed' do
    it 'switches tenant and loads the seed file' do
      allow(Apartment.config).to receive(:seed_data_file).and_return('/tmp/seeds.rb')
      allow(File).to receive(:exist?).with('/tmp/seeds.rb').and_return(true)
      expect(adapter).to receive(:load).with('/tmp/seeds.rb')

      adapter.seed('acme')
    end

    it 'does nothing when seed_data_file is nil' do
      allow(Apartment.config).to receive(:seed_data_file).and_return(nil)
      expect(adapter).not_to receive(:load)

      adapter.seed('acme')
    end

    it 'does nothing when seed file does not exist' do
      allow(Apartment.config).to receive(:seed_data_file).and_return('/tmp/missing.rb')
      allow(File).to receive(:exist?).with('/tmp/missing.rb').and_return(false)
      expect(adapter).not_to receive(:load)

      adapter.seed('acme')
    end
  end

  describe '#process_excluded_models' do
    it 'establishes connections for each excluded model' do
      model_class = Class.new
      stub_const('GlobalUser', model_class)

      allow(Apartment.config).to receive(:excluded_models).and_return(['GlobalUser'])
      allow(Apartment.config).to receive(:default_tenant).and_return('public')

      expected_config = { adapter: 'postgresql', database: 'public' }
      expect(model_class).to receive(:establish_connection) do |arg|
        expect(arg).to eq(expected_config)
      end

      adapter.process_excluded_models
    end

    it 'handles multiple excluded models' do
      user_class = Class.new
      company_class = Class.new
      stub_const('GlobalUser', user_class)
      stub_const('GlobalCompany', company_class)

      allow(Apartment.config).to receive(:excluded_models).and_return(%w[GlobalUser GlobalCompany])
      allow(Apartment.config).to receive(:default_tenant).and_return('public')

      expect(user_class).to receive(:establish_connection)
      expect(company_class).to receive(:establish_connection)

      adapter.process_excluded_models
    end

    it 'does nothing when excluded_models is empty' do
      allow(Apartment.config).to receive(:excluded_models).and_return([])
      allow(Apartment.config).to receive(:default_tenant).and_return('public')

      # Should not raise
      adapter.process_excluded_models
    end
  end

  describe '#environmentify' do
    it 'prepends the environment when strategy is :prepend' do
      allow(Apartment.config).to receive(:environmentify_strategy).and_return(:prepend)
      expect(adapter.environmentify('acme')).to eq('test_acme')
    end

    it 'appends the environment when strategy is :append' do
      allow(Apartment.config).to receive(:environmentify_strategy).and_return(:append)
      expect(adapter.environmentify('acme')).to eq('acme_test')
    end

    it 'returns tenant as string when strategy is nil' do
      allow(Apartment.config).to receive(:environmentify_strategy).and_return(nil)
      expect(adapter.environmentify('acme')).to eq('acme')
    end

    it 'converts symbols to string when strategy is nil' do
      allow(Apartment.config).to receive(:environmentify_strategy).and_return(nil)
      expect(adapter.environmentify(:acme)).to eq('acme')
    end

    it 'calls the strategy when it is callable' do
      strategy = ->(tenant) { "custom_#{tenant}" }
      allow(Apartment.config).to receive(:environmentify_strategy).and_return(strategy)
      expect(adapter.environmentify('acme')).to eq('custom_acme')
    end
  end

  describe '#default_tenant' do
    it 'delegates to Apartment.config.default_tenant' do
      expect(adapter.default_tenant).to eq('public')
    end
  end

  describe 'protected abstract methods' do
    it 'create_tenant raises NotImplementedError on the abstract class' do
      abstract = described_class.new(config)
      expect { abstract.send(:create_tenant, 't1') }.to raise_error(NotImplementedError)
    end

    it 'drop_tenant raises NotImplementedError on the abstract class' do
      abstract = described_class.new(config)
      expect { abstract.send(:drop_tenant, 't1') }.to raise_error(NotImplementedError)
    end
  end
end
