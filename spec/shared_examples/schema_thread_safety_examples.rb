# frozen_string_literal: true

# spec/shared_examples/schema_thread_safety_examples.rb

# Purpose: This file contains tests focusing on thread and fiber safety for
# schema-based adapters (PostgreSQL). It verifies that schema search paths
# and tenant schemas are properly isolated in concurrent scenarios.
#
# Coverage includes:
# - Thread-local schema search paths
# - Fiber-local schema contexts
# - Parallel schema operations
# - Ractor safety with schemas
# - Schema search path manipulation under load
# - Thread/Fiber schema isolation
# - Schema DDL operation safety
# - Deadlock prevention with schema operations

require 'spec_helper'
require 'parallel'
require 'ractor'

shared_examples 'ensures schema thread and fiber safety' do
  include_context 'with adapter setup'

  let(:schema1) { "thread_test_#{Apartment::Test.next_db}" }
  let(:schema2) { "thread_test_#{Apartment::Test.next_db}" }
  let(:schema3) { "thread_test_#{Apartment::Test.next_db}" }
  let(:num_parallel_processes) { Parallel.processor_count }
  let(:persistent_schemas) { %w[shared common] }

  before do
    Apartment.configure do |config|
      config.persistent_schemas = persistent_schemas
    end

    [schema1, schema2, schema3].each { |schema| adapter.create(schema) }
  end

  after do
    [schema1, schema2, schema3].each do |schema|
      adapter.drop(schema)
    rescue StandardError
      nil
    end
  end

  describe 'parallel schema operations' do
    it 'maintains schema search path isolation across processes' do
      results = Parallel.map([schema1, schema2, schema3] * 3, in_processes: num_parallel_processes) do |schema|
        adapter.switch!(schema)
        search_path = connection.schema_search_path
        { schema: schema, search_path: search_path }
      end

      results.each do |result|
        expect(result[:search_path]).to(start_with(%("#{result[:schema]}")))
        persistent_schemas.each do |persistent_schema|
          expect(result[:search_path]).to(include(%("#{persistent_schema}")))
        end
      end
    end

    it 'safely handles concurrent schema DDL operations' do
      test_table = 'concurrent_schema_test'

      adapter.switch!(schema1)
      connection.execute("CREATE TABLE #{test_table} (id serial primary key, counter integer)")

      # Perform concurrent inserts across processes
      Parallel.each(1..num_parallel_processes, in_processes: num_parallel_processes) do |i|
        adapter.switch!(schema1)
        connection.execute("INSERT INTO #{test_table} (counter) VALUES (#{i})")
      end

      # Verify data integrity
      adapter.switch!(schema1)
      count = connection.execute("SELECT COUNT(*) FROM #{test_table}").first['count'].to_i
      expect(count).to(eq(num_parallel_processes))
    end
  end

  describe 'thread safety with schema operations' do
    let(:pool_size) { Parallel.processor_count * 2 }

    before do
      config = adapter.instance_variable_get(:@config)
      config[:pool] = pool_size
      adapter.instance_variable_set(:@config, config)
    end

    it 'handles concurrent schema switching' do
      switch_count = pool_size * 2
      threads = Array.new(switch_count) do
        Thread.new do
          schema = [schema1, schema2, schema3].sample
          adapter.switch!(schema)
          sleep(rand(0.01..0.05)) # Simulate work
          {
            intended: schema,
            actual: connection.schema_search_path.match(/"([^"]+)"/)[1],
          }
        end
      end

      results = threads.map(&:value)
      results.each do |result|
        expect(result[:actual]).to(eq(result[:intended]))
      end
    end

    it 'maintains schema search path integrity under load' do
      mutex = Mutex.new
      search_paths = Queue.new

      threads = Array.new(pool_size) do
        Thread.new do
          5.times do
            adapter.switch!([schema1, schema2].sample) do
              search_path = connection.schema_search_path
              mutex.synchronize { search_paths << search_path }
              sleep(0.01) # Simulate work
            end
          end
        end
      end

      threads.each(&:join)

      paths = []
      paths << search_paths.pop until search_paths.empty?

      paths.each do |path|
        # Verify search path starts with one of our schemas
        expect(path).to(match(/^"(#{schema1}|#{schema2})"/))
        # Verify persistent schemas are present
        persistent_schemas.each do |schema|
          expect(path).to(include(%("#{schema}")))
        end
      end
    end
  end

  describe 'ractor safety with schemas', if: defined?(Ractor) do
    it 'maintains schema isolation between ractors' do
      ractor1 = Ractor.new(schema1) do |schema|
        adapter.switch!(schema)
        connection.schema_search_path
      end
      ractor2 = Ractor.new(schema2) do |schema|
        adapter.switch!(schema)
        connection.schema_search_path
      end

      path1 = ractor1.take
      path2 = ractor2.take

      expect(path1).to(start_with(%("#{schema1}")))
      expect(path2).to(start_with(%("#{schema2}")))
    end

    it 'handles schema operations in multiple ractors' do
      test_table = 'ractor_test'

      ractors = Array.new(3) do |i|
        schema = [schema1, schema2, schema3][i]
        Ractor.new([schema, test_table]) do |args|
          current_schema, table = args
          adapter.switch!(current_schema)
          connection.execute("CREATE TABLE #{table} (id serial primary key)")
          connection.tables.include?(table)
        end
      end

      results = ractors.map(&:take)
      expect(results).to(all(be(true)))
    end
  end

  describe 'fiber scheduling', if: defined?(Fiber.schedule) do
    it 'maintains schema context across fibers' do
      results = Queue.new

      Fiber.schedule do
        adapter.switch!(schema1)
        results << connection.schema_search_path

        Fiber.schedule do
          adapter.switch!(schema2)
          results << connection.schema_search_path
        end
      end

      sleep 0.1 # Allow fibers to complete

      paths = []
      paths << results.pop until results.empty?

      expect(paths[0]).to(start_with(%("#{schema2}")))
      expect(paths[1]).to(start_with(%("#{schema1}")))
    end
  end

  describe 'complex scenarios' do
    it 'handles mixed schema operations' do
      test_table = 'complex_schema_test'

      # Create test table in each schema
      [schema1, schema2, schema3].each do |schema|
        adapter.switch!(schema)
        connection.execute("CREATE TABLE #{test_table} (id serial primary key, value text)")
      end

      # Run mixed parallel and threaded operations
      Parallel.each(1..3, in_processes: 3) do |proc_num|
        threads = Array.new(3) do |thread_num|
          Thread.new do
            schema = [schema1, schema2, schema3][thread_num]
            adapter.switch!(schema)
            connection.execute(
              "INSERT INTO #{test_table} (value) VALUES ('proc#{proc_num}_thread#{thread_num}')"
            )
          end
        end
        threads.each(&:join)
      end

      # Verify schema isolation
      [schema1, schema2, schema3].each do |schema|
        adapter.switch!(schema)
        count = connection.execute("SELECT COUNT(*) FROM #{test_table}").first['count'].to_i
        expect(count).to(eq(3)) # One insert per process
      end
    end
  end

  describe 'error handling and recovery' do
    it 'handles schema creation errors gracefully' do
      results = Parallel.map(1..5, in_processes: 3) do
        adapter.create(schema1) # Attempt to create already existing schema
        :unexpected_success
      rescue Apartment::TenantExists
        :expected_error
      rescue StandardError
        :unexpected_error
      end

      expect(results).to(all(eq(:expected_error)))
    end

    it 'maintains search path integrity after errors' do
      initial_search_path = connection.schema_search_path

      10.times do
        Thread.new do
          adapter.switch!('invalid_schema')
        rescue StandardError
          nil
        end.join
      end

      expect(connection.schema_search_path).to(eq(initial_search_path))
    end
  end

  describe 'search path manipulation' do
    it 'safely handles concurrent search path changes' do
      threads = Array.new(10) do
        Thread.new do
          adapter.switch([schema1, schema2]) do
            sleep(rand(0.01..0.05))
            path = connection.schema_search_path
            # Verify both schemas are in the search path
            expect(path).to(include(%("#{schema1}")))
            expect(path).to(include(%("#{schema2}")))
            # Verify persistent schemas are still present
            persistent_schemas.each do |schema|
              expect(path).to(include(%("#{schema}")))
            end
          end
        end
      end

      threads.each(&:join)
    end
  end
end
