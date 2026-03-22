# frozen_string_literal: true

require 'active_support/notifications'

module Apartment
  # Thin wrapper around ActiveSupport::Notifications.
  # Known events: create, drop, evict (all namespaced as *.apartment).
  module Instrumentation
    def self.instrument(event, payload = {}, &block)
      event_name = "#{event}.apartment"
      if block
        ActiveSupport::Notifications.instrument(event_name, payload, &block)
      else
        ActiveSupport::Notifications.instrument(event_name, payload) { }
      end
    end
  end
end
