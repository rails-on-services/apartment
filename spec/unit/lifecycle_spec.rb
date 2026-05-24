# frozen_string_literal: true

require 'spec_helper'

RSpec.describe(Apartment::Lifecycle) do
  describe '.notify_created' do
    it 'publishes a create.apartment event carrying the tenant name' do
      events = []
      ActiveSupport::Notifications.subscribe('create.apartment') { |event| events << event }

      described_class.notify_created('acme')

      expect(events.size).to(eq(1))
      expect(events.first.payload).to(include(tenant: 'acme'))
    ensure
      ActiveSupport::Notifications.unsubscribe('create.apartment')
    end
  end

  describe '.notify_dropped' do
    it 'publishes a drop.apartment event carrying the tenant name' do
      events = []
      ActiveSupport::Notifications.subscribe('drop.apartment') { |event| events << event }

      described_class.notify_dropped('acme')

      expect(events.size).to(eq(1))
      expect(events.first.payload).to(include(tenant: 'acme'))
    ensure
      ActiveSupport::Notifications.unsubscribe('drop.apartment')
    end
  end
end
