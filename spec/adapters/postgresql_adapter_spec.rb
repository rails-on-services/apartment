# frozen_string_literal: true

if !defined?(JRUBY_VERSION) && ENV['DATABASE_ENGINE'] == 'postgresql'

  require 'spec_helper'
  require 'apartment/adapters/postgresql_adapter'

  describe Apartment::Adapters::PostgresqlAdapter, database: :postgresql do
    subject { Apartment::Tenant.adapter }

    it_behaves_like 'a generic apartment adapter callbacks'

    context 'when using schemas with schema.rb' do
      before { Apartment.use_schemas = true }

      # Not sure why, but somehow using let(:tenant_names) memoizes for the whole example group, not just each test
      def tenant_names
        ActiveRecord::Base.connection.execute('SELECT nspname FROM pg_namespace;').collect { |row| row['nspname'] }
      end

      let(:default_tenant) { subject.switch { ActiveRecord::Base.connection.schema_search_path.delete('"') } }

      it_behaves_like 'a generic apartment adapter'
      it_behaves_like 'a schema based apartment adapter'
    end

    context 'when using schemas with SQL dump' do
      before do
        Apartment.use_schemas = true
        Apartment.use_sql = true
      end

      after do
        Apartment::Tenant.drop('has-dashes') if Apartment.connection.schema_exists? 'has-dashes'
      end

      # Not sure why, but somehow using let(:tenant_names) memoizes for the whole example group, not just each test
      def tenant_names
        ActiveRecord::Base.connection.execute('SELECT nspname FROM pg_namespace;').collect { |row| row['nspname'] }
      end

      let(:default_tenant) { subject.switch { ActiveRecord::Base.connection.schema_search_path.delete('"') } }

      it_behaves_like 'a generic apartment adapter'
      it_behaves_like 'a schema based apartment adapter'

      it 'allows for dashes in the schema name' do
        expect { Apartment::Tenant.create('has-dashes') }.not_to raise_error
      end
    end

    context 'when using connections' do
      before { Apartment.use_schemas = false }

      # Not sure why, but somehow using let(:tenant_names) memoizes for the whole example group, not just each test
      def tenant_names
        connection.execute('select datname from pg_database;').collect { |row| row['datname'] }
      end

      let(:default_tenant) { subject.switch { ActiveRecord::Base.connection.current_database } }

      it_behaves_like 'a generic apartment adapter'
      it_behaves_like 'a generic apartment adapter able to handle custom configuration'
      it_behaves_like 'a connection based apartment adapter'
    end

    context 'when using pg_exclude_clone_tables with SQL dump' do
      before do
        Apartment.excluded_models = ['Company']
        Apartment.use_schemas = true
        Apartment.use_sql = true
        Apartment.pg_exclude_clone_tables = true
        ActiveRecord::Base.connection.execute <<-PROCEDURE
          CREATE OR REPLACE FUNCTION test_function() RETURNS INTEGER AS $function$
          DECLARE
            r1 INTEGER;
            r2 INTEGER;
          BEGIN
            SELECT COUNT(*) INTO r1 FROM public.companies;
            SELECT COUNT(*) INTO r2 FROM public.users;
            RETURN r1 + r2;
          END;
          $function$ LANGUAGE plpgsql;
        PROCEDURE
      end

      after do
        Apartment::Tenant.drop('has-procedure') if Apartment.connection.schema_exists? 'has-procedure'
        ActiveRecord::Base.connection.execute('DROP FUNCTION IF EXISTS test_function();')
        # Apartment::Tenant.init creates per model connection.
        # Remove the connection after testing not to unintentionally keep the connection across tests.
        Apartment.excluded_models.each do |excluded_model|
          excluded_model.constantize.remove_connection
        end
      end

      # Not sure why, but somehow using let(:tenant_names) memoizes for the whole example group, not just each test
      def tenant_names
        ActiveRecord::Base.connection.execute('SELECT nspname FROM pg_namespace;').collect { |row| row['nspname'] }
      end

      let(:default_tenant) { subject.switch { ActiveRecord::Base.connection.schema_search_path.delete('"') } }
      let(:c) { rand(5) }
      let(:u) { rand(5) }

      it_behaves_like 'a generic apartment adapter'
      it_behaves_like 'a schema based apartment adapter'

      # rubocop:disable RSpec/ExampleLength
      it 'not change excluded_models in the procedure code' do
        Apartment::Tenant.init
        Apartment::Tenant.create('has-procedure')
        Apartment::Tenant.switch!('has-procedure')
        c.times { Company.create }
        u.times { User.create }
        count = ActiveRecord::Base.connection.execute('SELECT test_function();')[0]['test_function']
        expect(count).to(eq(Company.count + User.count))
        Company.delete_all
      end
      # rubocop:enable RSpec/ExampleLength
    end
  end
end
