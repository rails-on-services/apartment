# frozen_string_literal: true

# spec/shared_examples/connection_concurrent_examples.rb

# Purpose: This file contains tests focusing on thread and fiber safety for
# connection-based adapters. It verifies that tenant connections are properly
# isolated in concurrent scenarios and that no connection state leaks between
# threads or fibers.
#
# Coverage includes:
# - Thread-local tenant connections
# - Fiber-local tenant connections
# - Parallel processing with multiple tenants
# - Ractor safety
# - Connection pool exhaustion handling
# - Thread/Fiber tenant isolation
# - Connection cleanup
# - Deadlock prevention
#
# These tests ensure thread-safety in multi-threaded and parallel environments
# and fiber-safety for async operations.

require 'rails_helper'

RSpec.shared_examples('handles concurrent connection operations') do
  include_context 'with adapter setup'

  let(:tenant1) { Apartment::Test.next_db }
  let(:tenant2) { Apartment::Test.next_db }
  let(:tenant3) { Apartment::Test.next_db }
  let(:num_parallel_processes) { Parallel.processor_count }

  before do
    [tenant1, tenant2, tenant3].each { |db| adapter.create(db) }
  end

  after do
    [tenant1, tenant2, tenant3].each do |db|
      adapter.drop(db)
    rescue StandardError
      nil
    end
  end

  describe 'parallel execution' do
    it 'handles tenant switching across parallel processes' do
      results = Parallel.map([tenant1, tenant2, tenant3] * 3, in_processes: num_parallel_processes) do |tenant|
        adapter.switch!(tenant)
        { tenant: tenant, current: adapter.current }
      end

      results.each do |result|
        expect(result[:current]).to(eq(result[:tenant]))
      end
    end

    it 'maintains data isolation in parallel processes' do
      adapter.switch!(tenant1)
      connection.execute('CREATE TABLE parallel_test (id integer, value text)')

      # Write data from multiple processes
      Parallel.each(1..num_parallel_processes, in_processes: num_parallel_processes) do |i|
        adapter.switch!(tenant1)
        connection.execute("INSERT INTO parallel_test VALUES (#{i}, 'test#{i}')")
      end

      # Verify all records were written
      adapter.switch!(tenant1)
      count = connection.execute('SELECT COUNT(*) FROM parallel_test').first[0]
      expect(count).to(eq(num_parallel_processes))
    end
  end

  describe 'thread safety with connection pools' do
    let(:pool_size) { Parallel.processor_count * 2 } # More realistic pool size

    before do
      config = adapter.instance_variable_get(:@config)
      config[:pool] = pool_size
      adapter.instance_variable_set(:@config, config)
    end

    it 'handles high-concurrency tenant switching' do
      switch_count = pool_size * 2
      threads = Array.new(switch_count) do
        Thread.new do
          tenant = [tenant1, tenant2, tenant3].sample
          adapter.switch!(tenant)
          sleep(rand(0.01..0.05)) # Simulate work
          adapter.current
        end
      end

      results = threads.map(&:value)
      expect(results).to(all(be_in([tenant1, tenant2, tenant3])))
    end

    it 'maintains connection pool size limits' do
      active_connections = Queue.new
      mutex = Mutex.new
      max_seen_connections = 0

      threads = Array.new(pool_size) do
        Thread.new do
          5.times do
            adapter.switch!(tenant1) do
              mutex.synchronize do
                active_connections << connection.object_id
                current = active_connections.size
                max_seen_connections = current if current > max_seen_connections
              end
              sleep(0.01)
              mutex.synchronize { active_connections.pop }
            end
          end
        end
      end

      threads.each(&:join)
      expect(max_seen_connections).to(be <= pool_size)
    end
  end

  describe 'ractor safety' do
    it 'maintains tenant isolation between ractors' do
      results = []
      ractor1 = Ractor.new(tenant1) do |t|
        adapter.switch!(t)
        adapter.current
      end
      ractor2 = Ractor.new(tenant2) do |t|
        adapter.switch!(t)
        adapter.current
      end

      results << ractor1.take
      results << ractor2.take

      expect(results).to(contain_exactly(tenant1, tenant2))
    end

    it 'handles tenant operations in multiple ractors' do
      ractors = Array.new(3) do |i|
        tenant = [tenant1, tenant2, tenant3][i]
        Ractor.new(tenant) do |t|
          adapter.switch!(t)
          connection.execute('SELECT 1')
          adapter.current
        end
      end

      results = ractors.map(&:take)
      expect(results).to(contain_exactly(tenant1, tenant2, tenant3))
    end
  end

  describe 'fiber scheduling' do
    it 'maintains tenant context in fiber scheduler', if: defined?(Fiber.schedule) do
      results = Queue.new

      Fiber.schedule do
        adapter.switch!(tenant1)
        results << adapter.current

        Fiber.schedule do
          adapter.switch!(tenant2)
          results << adapter.current
        end
      end

      sleep 0.1 # Allow fibers to complete
      expect(results.size).to(eq(2))
      expect(results.pop).to(eq(tenant2))
      expect(results.pop).to(eq(tenant1))
    end
  end

  describe 'complex scenarios' do
    it 'handles mixed parallel and threaded access' do
      # Create tables in each tenant
      [tenant1, tenant2, tenant3].each do |tenant|
        adapter.switch!(tenant)
        connection.execute('CREATE TABLE mixed_test (id integer, value text)')
      end

      # Use parallel processes with threads inside
      Parallel.each(1..3, in_processes: 3) do |proc_num|
        threads = Array.new(3) do |thread_num|
          Thread.new do
            tenant = [tenant1, tenant2, tenant3][thread_num]
            adapter.switch!(tenant)
            connection.execute(
              "INSERT INTO mixed_test VALUES (#{(proc_num * 10) + thread_num}, 'test')"
            )
          end
        end
        threads.each(&:join)
      end

      # Verify data isolation
      [tenant1, tenant2, tenant3].each do |tenant|
        adapter.switch!(tenant)
        count = connection.execute('SELECT COUNT(*) FROM mixed_test').first[0]
        expect(count).to(eq(3)) # One insert per process
      end
    end

    it 'handles connection pool sharing under load' do
      conn_ids = Queue.new
      mutex = Mutex.new

      # Track unique connection IDs
      threads = Array.new(20) do |i|
        Thread.new do
          tenant = [tenant1, tenant2, tenant3][i % 3]
          adapter.switch!(tenant) do
            mutex.synchronize { conn_ids << connection.object_id }
            sleep(rand(0.01..0.05)) # Simulate work
          end
        end
      end

      threads.each(&:join)
      unique_connections = Set.new
      conn_ids.size.times { unique_connections << conn_ids.pop }

      # Should reuse connections from pool
      expect(unique_connections.size).to(be <= pool_size)
    end
  end

  describe 'error handling and recovery' do
    it 'recovers from tenant switching errors in parallel' do
      results = Parallel.map(1..5, in_processes: 3) do
        adapter.switch!('nonexistent_tenant')
        :success
      rescue Apartment::TenantNotFound
        :expected_error
      rescue StandardError
        :unexpected_error
      end

      expect(results).to(all(eq(:expected_error)))
    end

    it 'maintains pool health after connection errors' do
      initial_size = count_active_connections

      10.times do
        Thread.new do
          adapter.switch!('bad_tenant')
        rescue StandardError
          nil
        end.join
      end

      # Allow connection reaping
      sleep 0.1
      expect(count_active_connections).to(eq(initial_size))
    end
  end

  private

  def count_active_connections
    ActiveRecord::Base.connection_handler.connection_pools.sum do |_, pool|
      pool.connections.count
    end
  end
end
