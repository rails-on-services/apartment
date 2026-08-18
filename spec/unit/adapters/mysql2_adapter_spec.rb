# frozen_string_literal: true

require 'spec_helper'
require 'active_record' # defines ActiveRecord::NoDatabaseError/StatementInvalid for the fail-safe contract specs
require_relative '../../../lib/apartment/adapters/mysql2_adapter'
require_relative '../../../lib/apartment/adapters/trilogy_adapter'

# Minimal ActiveRecord stubs for SQL execution tests.
unless defined?(ActiveRecord::Base)
  module ActiveRecord
    class Base
      def self.connection
        raise('stub: override with allow in tests')
      end
    end
  end
end

# Shared examples for MySQL-family adapters (MySQL2 and Trilogy share identical behavior).
RSpec.shared_examples('a MySQL adapter') do
  let(:connection_config) { { adapter: adapter_name, host: 'localhost', database: 'myapp' } }
  let(:adapter) { described_class.new(connection_config) }

  before do
    Apartment.configure do |c|
      c.tenant_strategy = :database_name
      c.tenants_provider = -> { %w[t1 t2] }
      c.default_tenant = 'myapp'
      c.schema_load_strategy = nil
    end
  end

  # Helper: reconfigure Apartment with overrides (Config is frozen after configure,
  # so we must reconfigure rather than stub individual accessors).
  def reconfigure(**overrides)
    Apartment.configure do |c|
      c.tenant_strategy = :database_name
      c.tenants_provider = -> { %w[t1 t2] }
      c.default_tenant = 'myapp'
      c.schema_load_strategy = nil
      overrides.each { |key, val| c.send(:"#{key}=", val) }
    end
  end

  describe '#resolve_connection_config' do
    it 'returns config with database key set to tenant name (nil strategy = plain name)' do
      result = adapter.resolve_connection_config('acme')

      expect(result['database']).to(eq('acme'))
    end

    it 'stringifies all config keys' do
      result = adapter.resolve_connection_config('acme')

      expect(result.keys).to(all(be_a(String)))
      expect(result['adapter']).to(eq(adapter_name))
      expect(result['host']).to(eq('localhost'))
    end

    it 'uses environmentify with :prepend strategy' do
      reconfigure(environmentify_strategy: :prepend)
      allow(Rails).to(receive(:env).and_return('staging'))

      result = adapter.resolve_connection_config('acme')

      expect(result['database']).to(eq('staging_acme'))
    end

    it 'uses environmentify with :append strategy' do
      reconfigure(environmentify_strategy: :append)
      allow(Rails).to(receive(:env).and_return('staging'))

      result = adapter.resolve_connection_config('acme')

      expect(result['database']).to(eq('acme_staging'))
    end

    it 'preserves all original connection config keys' do
      config = { adapter: adapter_name, host: 'db.example.com', database: 'app', port: 3306, pool: 10 }
      local_adapter = described_class.new(config)

      result = local_adapter.resolve_connection_config('tenant1')

      expect(result['port']).to(eq(3306))
      expect(result['pool']).to(eq(10))
      expect(result['host']).to(eq('db.example.com'))
    end

    it 'does not mutate the original connection_config' do
      adapter.resolve_connection_config('acme')

      expect(adapter.connection_config).to(eq(connection_config))
      expect(adapter.connection_config[:database]).to(eq('myapp'))
    end
  end

  describe '#shared_pinned_connection?' do
    it 'returns true (MySQL supports cross-database queries on same server)' do
      expect(adapter.shared_pinned_connection?).to(be(true))
    end

    it 'returns false when force_separate_pinned_pool is true' do
      reconfigure(force_separate_pinned_pool: true)
      expect(adapter.shared_pinned_connection?).to(be(false))
    end
  end

  # Qualification itself lives in AbstractAdapter; this adapter only supplies
  # the qualifier. End-to-end table_name behaviour is covered for real (no
  # mutator mocks) in spec/unit/adapters/pinned_table_qualification_spec.rb.
  describe '#pinned_table_qualifier' do
    it 'is the default database name from base_config' do
      expect(adapter.pinned_table_qualifier).to(eq('myapp'))
    end
  end

  describe '#create (via create_tenant)' do
    let(:connection) { double('Connection') }

    before do
      allow(ActiveRecord::Base).to(receive(:connection).and_return(connection))
      allow(Apartment::Instrumentation).to(receive(:instrument))
    end

    it 'executes CREATE DATABASE with quoted environmentified name' do
      allow(connection).to(receive(:quote_table_name).with('acme').and_return('`acme`'))
      expect(connection).to(receive(:execute).with('CREATE DATABASE IF NOT EXISTS `acme`'))

      adapter.create('acme')
    end

    it 'quotes tenant names that need escaping' do
      allow(connection).to(receive(:quote_table_name).with('my-tenant').and_return('`my-tenant`'))
      expect(connection).to(receive(:execute).with('CREATE DATABASE IF NOT EXISTS `my-tenant`'))

      adapter.create('my-tenant')
    end

    it 'uses environmentified name for CREATE DATABASE' do
      reconfigure(environmentify_strategy: :prepend)
      allow(Rails).to(receive(:env).and_return('test'))
      allow(connection).to(receive(:quote_table_name).with('test_acme').and_return('`test_acme`'))
      expect(connection).to(receive(:execute).with('CREATE DATABASE IF NOT EXISTS `test_acme`'))

      adapter.create('acme')
    end

    it 'validates the environmentified name against MySQL length limit' do
      # Raw name is 60 chars (valid for MySQL 64 limit), but "test_" prefix makes 65 (exceeds 64)
      reconfigure(environmentify_strategy: :prepend)
      allow(Rails).to(receive(:env).and_return('test'))

      tenant = 'a' * 60
      expect { adapter.create(tenant) }
        .to(raise_error(Apartment::ConfigurationError, /too long.*65.*max 64/))
    end
  end

  describe '#standard_privilege_statements' do
    let(:connection) { double('Connection') }

    def context(phase)
      Apartment::Privileges::Context.new(
        tenant: 'acme', container_name: 'acme_test', connection: connection,
        db_role: 'db_manager@%', phase: phase
      )
    end

    before do
      allow(connection).to(receive(:quote_table_name)) { |name| "`#{name}`" }
      allow(connection).to(receive(:quote)) { |value| "'#{value}'" }
      reconfigure
    end

    # MySQL's database-scoped grant is pattern-based: it already covers tables the
    # import and later migrations create, so there is nothing to do afterwards.
    # This asymmetry with PostgreSQL is why statements live behind an adapter seam.
    it 'grants once, before the schema load', :aggregate_failures do
      statements = adapter.standard_privilege_statements(
        context(:before_schema_load), grant_to: 'app_user', include_functions: true
      )

      expect(statements.size).to(eq(1))
      expect(statements.first).to(include("GRANT SELECT, INSERT, UPDATE, DELETE ON `acme_test`.* TO 'app_user'@'%'"))
    end

    it 'needs no statements after the schema load' do
      statements = adapter.standard_privilege_statements(
        context(:after_schema_load), grant_to: 'app_user', include_functions: true
      )

      expect(statements).to(be_empty)
    end

    it 'grants to every account it is given' do
      statements = adapter.standard_privilege_statements(
        context(:before_schema_load), grant_to: %w[app_web app_worker], include_functions: true
      )

      expect(statements.first).to(include("TO 'app_web'@'%', 'app_worker'@'%'"))
    end

    it 'raises on a phase it does not know, rather than returning nothing' do
      expect do
        adapter.standard_privilege_statements(context(:sometime_later), grant_to: 'app_user')
      end.to(raise_error(Apartment::ConfigurationError, /Unknown privilege policy phase/))
    end

    # 'me@localhost' is a legal MySQL username, so splitting on the last @ would
    # guess wrong. standard grants to role@'%' and refuses anything else, rather
    # than quoting the whole value into a different account than the caller meant.
    it 'refuses a grant_to carrying a host, naming the policy escape hatch', :aggregate_failures do
      raised = nil
      begin
        adapter.standard_privilege_statements(
          context(:before_schema_load), grant_to: 'app_user@10.0.0.5', include_functions: true
        )
      rescue StandardError => e
        raised = e
      end

      expect(raised).to(be_a(Apartment::ConfigurationError))
      expect(raised.message).to(include('bare role names'))
      expect(raised.message).to(include('tenant_privilege_policy'))
    end
  end

  describe '#drop (via drop_tenant)' do
    let(:connection) { double('Connection') }
    let(:pool_manager) { Apartment.pool_manager }

    before do
      allow(ActiveRecord::Base).to(receive(:connection).and_return(connection))
      allow(Apartment::Instrumentation).to(receive(:instrument))
      allow(pool_manager).to(receive(:remove_tenant).and_return([]))
      allow(Apartment).to(receive(:deregister_shard))
    end

    it 'executes DROP DATABASE IF EXISTS with quoted environmentified name' do
      allow(connection).to(receive(:quote_table_name).with('acme').and_return('`acme`'))
      expect(connection).to(receive(:execute).with('DROP DATABASE IF EXISTS `acme`'))

      adapter.drop('acme')
    end

    it 'quotes tenant names that need escaping' do
      allow(connection).to(receive(:quote_table_name).with('my-tenant').and_return('`my-tenant`'))
      expect(connection).to(receive(:execute).with('DROP DATABASE IF EXISTS `my-tenant`'))

      adapter.drop('my-tenant')
    end

    it 'uses environmentified name for DROP DATABASE' do
      reconfigure(environmentify_strategy: :prepend)
      allow(Rails).to(receive(:env).and_return('test'))
      allow(connection).to(receive(:quote_table_name).with('test_acme').and_return('`test_acme`'))
      expect(connection).to(receive(:execute).with('DROP DATABASE IF EXISTS `test_acme`'))

      adapter.drop('acme')
    end
  end

  describe 'missing-tenant fail-safe contract' do
    it 'declares NoDatabaseError plus the wrapped ApartmentError as failsafe classes' do
      expect(adapter.failsafe_error_classes).to(eq([ActiveRecord::NoDatabaseError, Apartment::ApartmentError]))
    end

    it 'classifies only NoDatabaseError as a container error' do
      aggregate_failures do
        expect(adapter.send(:container_error?, ActiveRecord::NoDatabaseError.new('gone'))).to(be(true))
        expect(adapter.send(:container_error?, ActiveRecord::StatementInvalid.new('bug'))).to(be(false))
        expect(adapter.send(:container_error?, RuntimeError.new('x'))).to(be(false))
      end
    end
  end
end

RSpec.describe(Apartment::Adapters::Mysql2Adapter) do
  describe 'inheritance' do
    it 'is a subclass of AbstractAdapter' do
      expect(described_class).to(be < Apartment::Adapters::AbstractAdapter)
    end
  end

  it_behaves_like 'a MySQL adapter' do
    let(:adapter_name) { 'mysql2' }
  end
end

RSpec.describe(Apartment::Adapters::TrilogyAdapter) do
  describe 'inheritance' do
    it 'is a subclass of Mysql2Adapter' do
      expect(described_class).to(be < Apartment::Adapters::Mysql2Adapter)
    end

    it 'is a subclass of AbstractAdapter' do
      expect(described_class).to(be < Apartment::Adapters::AbstractAdapter)
    end
  end

  it_behaves_like 'a MySQL adapter' do
    let(:adapter_name) { 'trilogy' }
  end
end
