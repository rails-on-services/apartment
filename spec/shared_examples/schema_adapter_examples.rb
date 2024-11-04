# frozen_string_literal: true

# spec/shared_examples/schema_adapter_examples.rb

# Purpose: This file contains tests specific to PostgreSQL schema-based adapters.
# It builds on top of the core adapter functionality while testing schema-specific
# features and edge cases.
#
# Coverage includes:
# - Schema search path management
# - Sequence name handling and caching
# - Persistent schema configuration
# - Schema-specific operations:
#   - Multiple schema switching
#   - Schema name escaping
#   - Schema structure verification
#   - SQL-based schema loading
# - Default tenant behavior
# - Complex search path scenarios
# - Transaction-level schema switching
#
# These tests should only be run against PostgreSQL adapters using schema-based separation.

require 'spec_helper'
require_relative 'core_adapter_examples'
require_relative 'schema_thread_safety_examples'

# Tests PostgreSQL schema search path manipulation
shared_examples 'handles schema search paths', database: :postgresql do
  include_context 'with adapter setup'

  let(:persistent_schemas) { %w[shared common] }

  before do
    adapter.create(tenant_name)
    Apartment.configure do |config|
      config.persistent_schemas = persistent_schemas
    end
  end

  it 'includes persistent schemas in search path' do
    adapter.switch!(tenant_name)
    persistent_schemas.each do |schema|
      expect(connection.schema_search_path).to(include(%("#{schema}")))
    end
  end

  it 'prioritizes tenant schema in search path' do
    adapter.switch!(tenant_name)
    expect(connection.schema_search_path).to(start_with(%("#{tenant_name}")))
  end

  it 'falls back to default schema when no tenant specified' do
    adapter.reset
    expect(connection.schema_search_path).to(start_with(%("#{default_tenant}")))
  end
end

# Tests handling of PostgreSQL sequence operations
shared_examples 'handles schema sequences', database: :postgresql do
  include_context 'with adapter setup'

  before do
    Apartment.configure do |config|
      config.excluded_models = ['Company']
    end
    adapter.create(tenant_name)
  end

  it 'maintains proper sequence names within tenant' do
    in_tenant(tenant_name) do
      User.reset_sequence_name
      expect(User.sequence_name).to(eq("#{User.table_name}_id_seq"))
    end
  end

  it 'uses default tenant for excluded model sequences' do
    in_tenant(tenant_name) do
      Company.reset_sequence_name
      expect(Company.sequence_name).to(eq("#{default_tenant}.#{Company.table_name}_id_seq"))
    end
  end

  it 'handles sequence name caching properly' do
    in_tenant(tenant_name) do
      # Force sequence name to be cached
      User.sequence_name
      Company.sequence_name

      # Reset connection
      adapter.reset

      # Should still have proper sequence names
      expect(User.sequence_name).to(eq("#{User.table_name}_id_seq"))
      expect(Company.sequence_name).to(eq("#{default_tenant}.#{Company.table_name}_id_seq"))
    end
  end
end

# Tests management of persistent schemas
shared_examples 'handles schema persistence', database: :postgresql do
  include_context 'with adapter setup'

  let(:persistent_schemas) { %w[shared common] }

  before do
    adapter.create(tenant_name)
    Apartment.configure do |config|
      config.persistent_schemas = persistent_schemas
    end
  end

  it 'maintains persistent schemas after reset' do
    adapter.switch!(tenant_name)
    adapter.reset

    expect(connection.schema_search_path).to(end_with(
                                               persistent_schemas.map { |schema| %("#{schema}") }.join(', ')
                                             ))
  end

  it 'includes persistent schemas when switching tenants' do
    in_tenant(tenant_name) do
      persistent_schemas.each do |schema|
        expect(connection.schema_search_path).to(include(schema))
      end
    end
  end
end

# Tests PostgreSQL-specific schema operations
shared_examples 'handles schema specific operations', database: :postgresql do
  include_context 'with adapter setup'

  before do
    adapter.create(tenant_name)
    adapter.create(another_tenant)
  end

  it 'supports switching to multiple schemas' do
    adapter.switch([tenant_name, another_tenant]) do
      expect(connection.schema_search_path).to(include(%("#{tenant_name}")))
      expect(connection.schema_search_path).to(include(%("#{another_tenant}")))
    end
  end

  it 'properly escapes schema names' do
    special_tenant = 'test-schema-name'
    adapter.create(special_tenant)
    adapter.switch!(special_tenant)

    expect(connection.schema_search_path).to(include(%("#{special_tenant}")))
  ensure
    begin
      adapter.drop(special_tenant)
    rescue StandardError
      nil
    end
  end

  describe 'schema creation' do
    it 'creates schema with proper structure' do
      in_tenant(tenant_name) do
        # Test specific table presence or structure
        expect(connection.tables).to(include('users'))
        # Could add more specific schema structure tests
      end
    end

    context 'when use_sql is true' do
      before do
        Apartment.configure do |config|
          config.use_sql = true
          # Use specific blacklist for testing
          config.pg_excluded_names = ['some_excluded_function']
          # Tables that shouldn't be cloned for test cases
          config.pg_exclude_clone_tables = false
        end
      end

      after do
        Apartment.configure do |config|
          config.use_sql = false
          config.pg_excluded_names = []
          config.pg_exclude_clone_tables = false
        end
      end

      def setup_test_schema
        # Create a function in public schema that we want to copy
        connection.execute(<<-SQL)
          CREATE OR REPLACE FUNCTION test_function()
          RETURNS INTEGER AS $$
          DECLARE
            count INTEGER;
          BEGIN
            SELECT COUNT(*) INTO count FROM users;
            RETURN count;
          END;
          $$ LANGUAGE plpgsql;
        SQL

        # Create a materialized view in public schema
        connection.execute(<<-SQL)
          CREATE MATERIALIZED VIEW test_mat_view AS
          SELECT id, name FROM users;
        SQL
      end

      def cleanup_test_schema
        connection.execute('DROP FUNCTION IF EXISTS test_function();')
        connection.execute('DROP MATERIALIZED VIEW IF EXISTS test_mat_view;')
      end

      around do |example|
        setup_test_schema
        example.run
        cleanup_test_schema
      end

      it 'copies schema structure including advanced PostgreSQL features' do
        new_tenant = Faker::Internet.unique.domain_word

        adapter.create(new_tenant)

        in_tenant(new_tenant) do
          # Verify function was copied
          result = connection.execute('SELECT test_function();')
          expect(result[0]['test_function']).to(eq(0)) # Should be 0 as no users exist

          # Verify materialized view exists
          expect(connection.execute("SELECT COUNT(*) FROM pg_matviews WHERE matviewname = 'test_mat_view';")[0]['count'])
            .to(eq('1'))

          # Create some data and verify function works
          User.create!(name: 'test')
          result = connection.execute('SELECT test_function();')
          expect(result[0]['test_function']).to(eq(1))
        end

        adapter.drop(new_tenant)
      end

      context 'with excluded items' do
        before do
          Apartment.configure do |config|
            config.pg_excluded_names = ['test_excluded_function']
          end

          connection.execute(<<-SQL)
            CREATE OR REPLACE FUNCTION test_excluded_function()
            RETURNS INTEGER AS $$
            BEGIN
              RETURN 42;
            END;
            $$ LANGUAGE plpgsql;
          SQL
        end

        after do
          connection.execute('DROP FUNCTION IF EXISTS test_excluded_function();')
        end

        it 'does not copy excluded items to new schema' do
          new_tenant = Faker::Internet.unique.domain_word

          adapter.create(new_tenant)

          in_tenant(new_tenant) do
            # Function should not exist in new schema
            expect do
              connection.execute('SELECT test_excluded_function();')
            end.to(raise_error(ActiveRecord::StatementInvalid, /function test_excluded_function\(\) does not exist/))
          end

          adapter.drop(new_tenant)
        end
      end

      context 'with excluded tables' do
        before do
          Apartment.configure do |config|
            config.pg_exclude_clone_tables = true
            config.excluded_models = ['Company']
          end

          Company.create!(name: 'Test Company')
        end

        it 'maintains excluded tables in public schema' do
          new_tenant = Faker::Internet.unique.domain_word

          adapter.create(new_tenant)

          in_tenant(new_tenant) do
            # Should still be able to access Company from public schema
            expect(Company.count).to(eq(1))
            expect(Company.first.name).to(eq('Test Company'))

            # But the table should not exist in the new schema
            expect(connection.execute(<<~SQL.squish).values.flatten.first).to(eq('f'))
              SELECT EXISTS (
                SELECT FROM information_schema.tables
                WHERE table_schema = '#{new_tenant}'
                AND table_name = 'companies'
              );
            SQL
          end

          adapter.drop(new_tenant)
        end
      end
    end
  end
end

shared_examples 'handles default tenant behavior', database: :postgresql do
  include_context 'with adapter setup'

  before do
    adapter.create(tenant_name)
    Apartment.default_tenant = default_tenant
  end

  after { Apartment.default_tenant = nil }

  it 'uses default tenant in search path by default' do
    adapter.reset
    expect(connection.schema_search_path).to(start_with(%("#{default_tenant}")))
  end

  it 'excludes default tenant from tenant list' do
    expect(tenant_names).not_to(include(default_tenant))
  end

  it 'restores default tenant after dropping current tenant' do
    adapter.switch!(tenant_name) do
      adapter.drop(tenant_name)
    end
    expect(adapter.current).to(eq(default_tenant))
  end
end

shared_examples 'handles complex search paths', database: :postgresql do
  include_context 'with adapter setup'

  before do
    adapter.create(tenant_name)
    adapter.create(another_tenant)
  end

  it 'maintains proper search path order with multiple schemas' do
    adapter.switch([tenant_name, another_tenant]) do
      path_parts = connection.schema_search_path.split(',').map(&:strip)
      expect(path_parts[0]).to(eq(%("#{tenant_name}")))
      expect(path_parts[1]).to(eq(%("#{another_tenant}")))
    end
  end

  it 'handles search path changes during transaction' do
    adapter.switch(tenant_name) do
      ActiveRecord::Base.transaction do
        adapter.switch(another_tenant) do
          expect(connection.schema_search_path).to(start_with(%("#{another_tenant}")))
        end
        expect(connection.schema_search_path).to(start_with(%("#{tenant_name}")))
      end
    end
  end
end

shared_examples 'handles pg_exclude_clone_tables properly' do
  let(:tenant_name) { 'excluded-tables-test' }
  let(:excluded_model_count) { rand(1..5) }
  let(:included_model_count) { rand(1..5) }

  before do
    Apartment.configure do |config|
      config.excluded_models = ['Company']
      config.pg_exclude_clone_tables = true
    end

    # Create test function in public schema
    connection.execute(<<-SQL)
      CREATE OR REPLACE FUNCTION public.test_excluded_models_count()
      RETURNS INTEGER AS $$
      DECLARE
        excluded_count INTEGER;
        included_count INTEGER;
      BEGIN
        SELECT COUNT(*) INTO excluded_count FROM public.companies;
        SELECT COUNT(*) INTO included_count FROM public.users;
        RETURN excluded_count + included_count;
      END;
      $$ LANGUAGE plpgsql;
    SQL

    Apartment::Tenant.create(tenant_name)
  end

  after do
    Apartment::Tenant.drop(tenant_name)
    connection.execute('DROP FUNCTION IF EXISTS public.test_excluded_models_count();')

    # Clean up model connections
    Array(Apartment.excluded_models).each do |model|
      model.constantize.remove_connection
    end
  end

  it 'maintains excluded model access across schemas' do
    # Create records in public schema
    excluded_model_count.times { Company.create! }

    Apartment::Tenant.switch!(tenant_name) do
      # Create records in tenant schema
      included_model_count.times { User.create! }

      # Function should see both public and tenant records
      result = connection.execute('SELECT public.test_excluded_models_count();')
      total_count = result.first['test_excluded_models_count']

      expect(total_count).to(eq(Company.count + User.count))
      expect(Company.count).to(eq(excluded_model_count))
      expect(User.count).to(eq(included_model_count))
    end
  end
end

shared_examples 'a schema based apartment adapter', database: :postgresql do
  # Include core adapter functionality first
  it_behaves_like 'a basic apartment adapter'

  # Then test schema-specific features
  it_behaves_like 'handles schema search paths'
  it_behaves_like 'handles schema sequences'
  it_behaves_like 'handles schema persistence'
  it_behaves_like 'handles schema specific operations'
  it_behaves_like 'ensures thread and fiber safety'
  it_behaves_like 'handles pg_exclude_clone_tables properly'
end
