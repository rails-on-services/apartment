# frozen_string_literal: true

require 'active_support/notifications'

module Apartment
  module Instrumentation
    EVENTS = %i[switch create drop evict pool_stats].freeze

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
