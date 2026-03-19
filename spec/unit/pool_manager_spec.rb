# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Apartment::PoolManager do
  subject(:manager) { described_class.new }

  describe '#fetch_or_create' do
    it 'creates and caches a new entry' do
      result = manager.fetch_or_create('tenant_a') { 'pool_a' }
      expect(result).to eq('pool_a')
    end

    it 'returns cached entry on subsequent calls' do
      call_count = 0
      2.times do
        manager.fetch_or_create('tenant_a') { call_count += 1; "pool_#{call_count}" }
      end
      expect(manager.fetch_or_create('tenant_a') { 'new' }).to eq('pool_1')
    end

    it 'updates last_accessed timestamp' do
      manager.fetch_or_create('tenant_a') { 'pool_a' }
      stats = manager.stats_for('tenant_a')
      expect(stats[:last_accessed]).to be_within(1).of(Time.now)
    end
  end

  describe '#remove' do
    it 'removes a tracked pool' do
      manager.fetch_or_create('tenant_a') { 'pool_a' }
      manager.remove('tenant_a')
      expect(manager.tracked?('tenant_a')).to be false
    end

    it 'returns the removed value' do
      manager.fetch_or_create('tenant_a') { 'pool_a' }
      expect(manager.remove('tenant_a')).to eq('pool_a')
    end

    it 'returns nil for unknown tenants' do
      expect(manager.remove('unknown')).to be_nil
    end
  end

  describe '#idle_tenants' do
    it 'returns tenants idle beyond threshold' do
      manager.fetch_or_create('old') { 'pool_old' }
      manager.instance_variable_get(:@timestamps)['old'] = Time.now - 600
      manager.fetch_or_create('recent') { 'pool_recent' }

      idle = manager.idle_tenants(timeout: 300)
      expect(idle).to include('old')
      expect(idle).not_to include('recent')
    end
  end

  describe '#lru_tenants' do
    it 'returns tenants sorted by least recently accessed' do
      manager.fetch_or_create('a') { 'pool_a' }
      manager.instance_variable_get(:@timestamps)['a'] = Time.now - 300
      manager.fetch_or_create('b') { 'pool_b' }
      manager.instance_variable_get(:@timestamps)['b'] = Time.now - 200
      manager.fetch_or_create('c') { 'pool_c' }

      lru = manager.lru_tenants(count: 2)
      expect(lru).to eq(%w[a b])
    end
  end

  describe '#stats' do
    it 'returns pool count and tenant list' do
      manager.fetch_or_create('a') { 'pool_a' }
      manager.fetch_or_create('b') { 'pool_b' }

      stats = manager.stats
      expect(stats[:total_pools]).to eq(2)
      expect(stats[:tenants]).to contain_exactly('a', 'b')
    end
  end

  describe '#clear' do
    it 'removes all tracked pools' do
      manager.fetch_or_create('a') { 'pool_a' }
      manager.fetch_or_create('b') { 'pool_b' }
      manager.clear
      expect(manager.stats[:total_pools]).to eq(0)
    end
  end

  describe 'thread safety' do
    it 'handles concurrent fetch_or_create without duplicates' do
      results = Concurrent::Array.new
      threads = 10.times.map do
        Thread.new { results << manager.fetch_or_create('shared') { SecureRandom.hex } }
      end
      threads.each(&:join)

      expect(results.uniq.size).to eq(1)
    end
  end
end
