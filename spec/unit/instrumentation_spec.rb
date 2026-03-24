# frozen_string_literal: true

require 'spec_helper'

RSpec.describe(Apartment::Instrumentation) do
  describe '.instrument' do
    it 'publishes switch.apartment events' do
      events = []
      ActiveSupport::Notifications.subscribe('switch.apartment') { |event| events << event }

      described_class.instrument(:switch, tenant: 'acme', previous_tenant: 'public')

      expect(events.size).to(eq(1))
      expect(events.first.payload).to(include(tenant: 'acme', previous_tenant: 'public'))
    ensure
      ActiveSupport::Notifications.unsubscribe('switch.apartment')
    end

    it 'publishes create.apartment events' do
      events = []
      ActiveSupport::Notifications.subscribe('create.apartment') { |event| events << event }

      described_class.instrument(:create, tenant: 'new_tenant')

      expect(events.size).to(eq(1))
      expect(events.first.payload[:tenant]).to(eq('new_tenant'))
    ensure
      ActiveSupport::Notifications.unsubscribe('create.apartment')
    end

    it 'forwards blocks and returns block result' do
      events = []
      ActiveSupport::Notifications.subscribe('switch.apartment') { |event| events << event }

      result = described_class.instrument(:switch, tenant: 'acme') { 'block_result' }

      expect(result).to(eq('block_result'))
      expect(events.size).to(eq(1))
    ensure
      ActiveSupport::Notifications.unsubscribe('switch.apartment')
    end

    it 'publishes evict.apartment events' do
      events = []
      ActiveSupport::Notifications.subscribe('evict.apartment') { |event| events << event }

      described_class.instrument(:evict, tenant: 'old', reason: :idle)

      expect(events.first.payload).to(include(tenant: 'old', reason: :idle))
    ensure
      ActiveSupport::Notifications.unsubscribe('evict.apartment')
    end
  end
end
