# frozen_string_literal: true

# lib/apartment/concerns/model.rb

require 'active_support/concern'

module Apartment
  module Model
    extend ActiveSupport::Concern

    class_methods do
      attr_reader :pinned_tenant

      # rubocop:disable ThreadSafety/ClassInstanceVariable
      def pin_tenant(tenant)
        raise(ConfigurationError, 'Cannot change pinned_tenant once set') if @pinned_tenant

        puts "Setting pinned_tenant to #{tenant.inspect}"
        @pinned_tenant = tenant
      end
      # rubocop:enable ThreadSafety/ClassInstanceVariable
    end
  end
end
