# frozen_string_literal: true

require 'spec_helper'

RSpec.describe(Apartment::PoolManager) do
  subject(:manager) { described_class.new }

  describe '#fetch_or_create' do
    it 'creates and caches a new entry' do
      result = manager.fetch_or_create('tenant_a') { 'pool_a' }
      expect(result).to(eq('pool_a'))
    end

    it 'returns cached entry on subsequent calls' do
      call_count = 0
      2.times do
        manager.fetch_or_create('tenant_a') do
          call_count += 1
          "pool_#{call_count}"
        end
      end
      expect(manager.fetch_or_create('tenant_a') { 'new' }).to(eq('pool_1'))
    end

    it 'tracks seconds_idle for the pool' do
      manager.fetch_or_create('tenant_a') { 'pool_a' }
      stats = manager.stats_for('tenant_a')
      expect(stats[:seconds_idle]).to(be_within(1).of(0))
    end
  end

  describe '#fetch_or_create when block raises' do
    it 'does not store a value and re-raises' do
      expect { manager.fetch_or_create('bad') { raise('pool creation failed') } }
        .to(raise_error(RuntimeError, 'pool creation failed'))
      expect(manager.tracked?('bad')).to(be(false))
    end
  end

  describe '#get' do
    it 'returns the pool for an existing tenant' do
      manager.fetch_or_create('tenant_a') { 'pool_a' }
      expect(manager.get('tenant_a')).to(eq('pool_a'))
    end

    it 'returns nil for unknown tenants' do
      expect(manager.get('unknown')).to(be_nil)
    end

    it 'resets seconds_idle on access' do
      manager.fetch_or_create('tenant_a') { 'pool_a' }
      manager.instance_variable_get(:@timestamps)['tenant_a'] = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 600
      manager.get('tenant_a')
      expect(manager.stats_for('tenant_a')[:seconds_idle]).to(be_within(1).of(0))
    end

    it 'does not create timestamps for unknown tenants' do
      manager.get('unknown')
      expect(manager.stats_for('unknown')).to(be_nil)
    end
  end

  describe '#remove' do
    it 'removes a tracked pool' do
      manager.fetch_or_create('tenant_a') { 'pool_a' }
      manager.remove('tenant_a')
      expect(manager.tracked?('tenant_a')).to(be(false))
    end

    it 'returns the removed value' do
      manager.fetch_or_create('tenant_a') { 'pool_a' }
      expect(manager.remove('tenant_a')).to(eq('pool_a'))
    end

    it 'returns nil for unknown tenants' do
      expect(manager.remove('unknown')).to(be_nil)
    end
  end

  describe '#idle_tenants' do
    it 'returns tenants idle beyond threshold' do
      manager.fetch_or_create('old') { 'pool_old' }
      manager.instance_variable_get(:@timestamps)['old'] = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 600
      manager.fetch_or_create('recent') { 'pool_recent' }

      idle = manager.idle_tenants(timeout: 300)
      expect(idle).to(include('old'))
      expect(idle).not_to(include('recent'))
    end
  end

  describe '#lru_tenants' do
    it 'returns tenants sorted by least recently accessed' do
      manager.fetch_or_create('a') { 'pool_a' }
      manager.instance_variable_get(:@timestamps)['a'] = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 300
      manager.fetch_or_create('b') { 'pool_b' }
      manager.instance_variable_get(:@timestamps)['b'] = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 200
      manager.fetch_or_create('c') { 'pool_c' }

      lru = manager.lru_tenants(count: 2)
      expect(lru).to(eq(%w[a b]))
    end
  end

  describe '#stats' do
    it 'returns pool count and tenant list' do
      manager.fetch_or_create('a') { 'pool_a' }
      manager.fetch_or_create('b') { 'pool_b' }

      stats = manager.stats
      expect(stats[:total_pools]).to(eq(2))
      expect(stats[:tenants]).to(contain_exactly('a', 'b'))
    end
  end

  describe '#clear' do
    it 'removes all tracked pools' do
      manager.fetch_or_create('a') { 'pool_a' }
      manager.fetch_or_create('b') { 'pool_b' }
      manager.clear
      expect(manager.stats[:total_pools]).to(eq(0))
    end
  end

  describe '#remove_tenant' do
    it 'removes all pools for the given tenant prefix' do
      manager.fetch_or_create('acme:writing') { 'pool_aw' }
      manager.fetch_or_create('acme:reading') { 'pool_ar' }
      manager.fetch_or_create('other:writing') { 'pool_ow' }

      removed = manager.remove_tenant('acme')

      expect(removed.map(&:first)).to(contain_exactly('acme:writing', 'acme:reading'))
      expect(manager.tracked?('acme:writing')).to(be(false))
      expect(manager.tracked?('acme:reading')).to(be(false))
      expect(manager.tracked?('other:writing')).to(be(true))
    end

    it 'returns empty array when no pools match' do
      manager.fetch_or_create('other:writing') { 'pool_ow' }
      expect(manager.remove_tenant('acme')).to(eq([]))
    end
  end

  describe '#evict_by_role' do
    it 'removes all pools with the given role suffix' do
      manager.fetch_or_create('acme:writing') { 'pool_aw' }
      manager.fetch_or_create('acme:db_manager') { 'pool_am' }
      manager.fetch_or_create('other:db_manager') { 'pool_om' }
      manager.fetch_or_create('other:writing') { 'pool_ow' }

      removed = manager.evict_by_role(:db_manager)

      expect(removed.map(&:first)).to(contain_exactly('acme:db_manager', 'other:db_manager'))
      expect(manager.tracked?('acme:db_manager')).to(be(false))
      expect(manager.tracked?('other:db_manager')).to(be(false))
      expect(manager.tracked?('acme:writing')).to(be(true))
      expect(manager.tracked?('other:writing')).to(be(true))
    end

    it 'returns empty array when no pools match' do
      manager.fetch_or_create('acme:writing') { 'pool_aw' }
      expect(manager.evict_by_role(:db_manager)).to(eq([]))
    end
  end

  describe 'thread safety' do
    it 'handles concurrent fetch_or_create without duplicates' do
      results = Concurrent::Array.new
      threads = Array.new(10) do
        Thread.new { results << manager.fetch_or_create('shared') { SecureRandom.hex } }
      end
      threads.each(&:join)

      expect(results.uniq.size).to(eq(1))
    end
  end
end
