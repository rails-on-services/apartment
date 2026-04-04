# frozen_string_literal: true

require 'active_support/concern'

module Apartment
  module Model
    extend ActiveSupport::Concern

    class_methods do
      # Declare this model as pinned to the default tenant.
      # Pinned models bypass tenant switching in ConnectionHandling —
      # their connection always targets the default tenant's database/schema.
      #
      # Safe to call before or after Apartment.activate!.
      # Idempotent: no-op if this class (or a parent) is already pinned.
      def pin_tenant
        return if apartment_pinned?

        @apartment_pinned = true
        Apartment.register_pinned_model(self)

        # If Apartment is already activated, process immediately (Zeitwerk autoload path).
        # Otherwise, activate! will process all registered models.
        Apartment.process_pinned_model(self) if Apartment.activated?
      end

      def apartment_pinned?
        return true if @apartment_pinned == true
        return false unless superclass.respond_to?(:apartment_pinned?)

        superclass.apartment_pinned?
      end
    end
  end
end
