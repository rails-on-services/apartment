# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Apartment::PoolReaper do
  let(:pool_manager) { Apartment::PoolManager.new }
  let(:disconnect_calls) { Concurrent::Array.new }
  let(:on_evict) { ->(tenant, _pool) { disconnect_calls << tenant } }

  after { described_class.stop }

  describe '.start / .stop' do
    it 'can start and stop without error' do
      described_class.start(
        pool_manager: pool_manager,
        interval: 0.1,
        idle_timeout: 0.2,
        on_evict: on_evict
      )
      expect(described_class).to be_running
      described_class.stop
      expect(described_class).not_to be_running
    end
  end

  describe 'idle eviction' do
    it 'evicts pools idle beyond timeout' do
      pool_manager.fetch_or_create('stale') { 'pool_stale' }
      pool_manager.instance_variable_get(:@timestamps)['stale'] = Time.now - 10

      pool_manager.fetch_or_create('fresh') { 'pool_fresh' }

      described_class.start(
        pool_manager: pool_manager,
        interval: 0.05,
        idle_timeout: 1,
        on_evict: on_evict
      )

      sleep 0.2

      expect(disconnect_calls).to include('stale')
      expect(pool_manager.tracked?('stale')).to be false
      expect(pool_manager.tracked?('fresh')).to be true
    end
  end

  describe 'max_total eviction' do
    it 'evicts LRU pools when over max' do
      3.times do |i|
        pool_manager.fetch_or_create("tenant_#{i}") { "pool_#{i}" }
        pool_manager.instance_variable_get(:@timestamps)["tenant_#{i}"] = Time.now - (300 - i * 100)
      end

      described_class.start(
        pool_manager: pool_manager,
        interval: 0.05,
        idle_timeout: 999,
        max_total: 2,
        on_evict: on_evict
      )

      sleep 0.2

      expect(pool_manager.stats[:total_pools]).to be <= 2
      expect(disconnect_calls).to include('tenant_0')
    end
  end

  describe 'protected tenants' do
    it 'never evicts the default tenant' do
      pool_manager.fetch_or_create('public') { 'pool_default' }
      pool_manager.instance_variable_get(:@timestamps)['public'] = Time.now - 9999

      described_class.start(
        pool_manager: pool_manager,
        interval: 0.05,
        idle_timeout: 1,
        default_tenant: 'public',
        on_evict: on_evict
      )

      sleep 0.2

      expect(pool_manager.tracked?('public')).to be true
      expect(disconnect_calls).not_to include('public')
    end
  end

  describe 'instrumentation' do
    it 'emits evict.apartment events on eviction' do
      events = Concurrent::Array.new
      ActiveSupport::Notifications.subscribe('evict.apartment') { |event| events << event }

      pool_manager.fetch_or_create('stale') { 'pool_stale' }
      pool_manager.instance_variable_get(:@timestamps)['stale'] = Time.now - 10

      described_class.start(
        pool_manager: pool_manager,
        interval: 0.05,
        idle_timeout: 1,
        on_evict: on_evict
      )

      sleep 0.2

      expect(events.any? { |e| e.payload[:tenant] == 'stale' }).to be true
    ensure
      ActiveSupport::Notifications.unsubscribe('evict.apartment')
    end
  end
end
