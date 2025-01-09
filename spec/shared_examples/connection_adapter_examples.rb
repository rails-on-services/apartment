# frozen_string_literal: true

# spec/shared_examples/connection_adapter_examples.rb

# Purpose: This file contains tests specific to database connection-based adapters
# (as opposed to schema-based separation). It builds on the core adapter functionality
# while testing connection-specific features and edge cases.
#
# Coverage includes:
# - Database connection management
# - Connection pool handling
# - Cross-database operations
# - Connection state preservation
# - Connection recovery scenarios
# - Custom database configuration
# - Transaction isolation
#
# These tests should be run against MySQL, SQLite, and non-schema PostgreSQL adapters.

require 'rails_helper'

RSpec.shared_examples('a connection based adapter') do
  include_context 'with adapter setup'

  describe 'connection management' do
    before { adapter.create(tenant_name) }

    describe 'connection handling' do
      it 'establishes unique connections per tenant' do
        original_connection_id = nil
        adapter.switch(tenant_name) do
          original_connection_id = connection.object_id
        end

        adapter.switch(another_tenant) do
          expect(connection.object_id).not_to(eq(original_connection_id))
        end
      end

      it 'maintains connection specific settings' do
        adapter.switch(tenant_name) do
          connection.execute("SET TIME_ZONE = '+00:00'")
          timezone = connection.execute('SELECT @@session.time_zone').first[0]
          expect(timezone).to(eq('+00:00'))
        end

        adapter.switch(another_tenant) do
          timezone = connection.execute('SELECT @@session.time_zone').first[0]
          expect(timezone).to(eq('SYSTEM'))
        end
      end

      it 'handles connection errors gracefully' do
        expect do
          adapter.switch('nonexistent_database') do
            connection.execute('SELECT 1')
          end
        end.to(raise_error(Apartment::TenantNotFound))
      end
    end

    describe 'connection pooling' do
      it 'creates separate connection pools per tenant' do
        adapter.create(tenant_name)
        original_pool = nil

        adapter.switch(tenant_name) do
          original_pool = ActiveRecord::Base.connection_pool
          expect(original_pool.connections.size).to(be >= 1)
        end

        adapter.switch!(another_tenant)
        expect(ActiveRecord::Base.connection_pool).not_to(eq(original_pool))
      end

      it 'cleans up connection pools on tenant drop' do
        adapter.create(tenant_name)
        pool_count_before = ActiveRecord::Base.connection_handler.connection_pools.count

        adapter.switch(tenant_name) do
          connection # Establish connection
        end

        adapter.drop(tenant_name)
        expect(ActiveRecord::Base.connection_handler.connection_pools.count).to(eq(pool_count_before))
      end

      it 'respects pool size configuration' do
        config = adapter.instance_variable_get(:@config)
        pool_size = config[:pool] || 5

        adapter.create(tenant_name)
        adapter.switch!(tenant_name)

        threads = Array.new(pool_size) do
          Thread.new do
            ActiveRecord::Base.connection.execute('SELECT 1')
            sleep(0.1)
          end
        end

        expect { threads.each(&:join) }.not_to(raise_error)
      end
    end
  end

  describe 'cross-database operations' do
    before do
      adapter.create(tenant_name)
      adapter.create(another_tenant)
    end

    it 'maintains data isolation between tenants' do
      adapter.switch(tenant_name) do
        connection.execute('CREATE TABLE IF NOT EXISTS items (id INT, name VARCHAR(255))')
        connection.execute("INSERT INTO items VALUES (1, 'tenant_1_item')")
      end

      adapter.switch(another_tenant) do
        connection.execute('CREATE TABLE IF NOT EXISTS items (id INT, name VARCHAR(255))')
        connection.execute("INSERT INTO items VALUES (1, 'tenant_2_item')")

        result = connection.execute('SELECT name FROM items WHERE id = 1').first
        expect(result[0]).to(eq('tenant_2_item'))
      end

      adapter.switch(tenant_name) do
        result = connection.execute('SELECT name FROM items WHERE id = 1').first
        expect(result[0]).to(eq('tenant_1_item'))
      end
    end

    describe 'excluded models' do
      before do
        Apartment.configure do |config|
          config.excluded_models = ['Company']
        end

        Company.create!(name: 'Global Corp')
      end

      it 'maintains access across databases' do
        adapter.switch(tenant_name) do
          expect(Company.find_by(name: 'Global Corp')).to(be_present)
        end

        adapter.switch(another_tenant) do
          expect(Company.find_by(name: 'Global Corp')).to(be_present)
        end
      end
    end
  end

  describe 'custom database configuration' do
    let(:custom_config) do
      base_config = adapter.instance_variable_get(:@config).dup
      base_config.merge(
        database: "custom_#{Apartment::Test.next_db}",
        pool: 2,
        variables: { 'group_concat_max_len' => '1000000' }
      )
    end

    before do
      Apartment.configure do |config|
        config.tenant_names = { tenant_name => custom_config }
        config.with_multi_server_setup = true
      end
    end

    it 'uses custom configuration for tenant' do
      adapter.create(tenant_name)

      adapter.switch(tenant_name) do
        current_db = if connection.adapter_name.downcase == 'postgresql'
                       connection.current_database
                     else
                       connection.instance_variable_get(:@config)[:database]
                     end
        expect(current_db).to(eq(custom_config[:database]))
      end
    end

    it 'respects custom pool settings' do
      adapter.create(tenant_name)

      adapter.switch(tenant_name) do
        pool = ActiveRecord::Base.connection_pool
        expect(pool.size).to(eq(custom_config[:pool]))
      end
    end
  end

  describe 'connection state management' do
    before { adapter.create(tenant_name) }

    describe 'transaction handling' do
      it 'preserves transaction state across switches' do
        adapter.switch(tenant_name) do
          ActiveRecord::Base.transaction do
            connection.execute('CREATE TABLE test_table (id INT)')

            adapter.switch(another_tenant) do
              connection.execute('CREATE TABLE other_table (id INT)')
              raise ActiveRecord::Rollback
            end

            connection.execute('INSERT INTO test_table VALUES (1)')
          end

          result = connection.execute('SELECT COUNT(*) FROM test_table').first
          expect(result[0]).to(eq(1))
        end

        adapter.switch(another_tenant) do
          expect do
            connection.execute('SELECT * FROM other_table')
          end.to(raise_error(ActiveRecord::StatementInvalid))
        end
      end

      it 'handles nested switches with transactions' do
        adapter.switch(tenant_name) do
          ActiveRecord::Base.transaction do
            connection.execute('CREATE TABLE parent (id INT)')

            adapter.switch(another_tenant) do
              ActiveRecord::Base.transaction do
                connection.execute('CREATE TABLE child (id INT)')
                raise ActiveRecord::Rollback
              end
            end

            connection.execute('INSERT INTO parent VALUES (1)')
          end

          expect(connection.tables).to(include('parent'))
        end

        adapter.switch(another_tenant) do
          expect(connection.tables).not_to(include('child'))
        end
      end
    end

    describe 'session state' do
      it 'resets after tenant switch' do
        adapter.switch(tenant_name) do
          connection.execute("SET @user_var = 'test'")
          result = connection.execute('SELECT @user_var').first
          expect(result[0]).to(eq('test'))
        end

        adapter.switch(another_tenant) do
          result = connection.execute('SELECT @user_var').first
          expect(result[0]).to(be_nil)
        end
      end
    end
  end
end
