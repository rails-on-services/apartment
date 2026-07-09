# frozen_string_literal: true

require 'active_support/notifications'

module Apartment
  # Thin wrapper around ActiveSupport::Notifications. All events are namespaced
  # *.apartment; see docs/observability.md for the authoritative event catalog.
  module Instrumentation
    def self.instrument(event, payload = {}, &block)
      event_name = "#{event}.apartment"
      if block
        ActiveSupport::Notifications.instrument(event_name, payload, &block)
      else
        ActiveSupport::Notifications.instrument(event_name, payload) {}
      end
    end
  end
end
