# frozen_string_literal: true

# Class instance variables are the intended pattern here: each AR model class
# tracks its own pinned state. Disabling for the entire file.
# rubocop:disable ThreadSafety/ClassInstanceVariable

require 'active_support/concern'

module Apartment
  module Model
    extend ActiveSupport::Concern

    class_methods do # rubocop:disable Metrics/BlockLength
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

        # Defer processing until the class body closes via TracePoint(:end),
        # so self.table_name and other declarations are visible.
        # For Class.new { } (tests), :end does not fire; call
        # process_pinned_model explicitly after the block.
        apartment_defer_processing! if Apartment.activated?
      end

      # Mark this class as pinned without triggering processing.
      # Used by process_pinned_model for shim-registered models that
      # need the concern included but are already being processed.
      def apartment_mark_pinned!
        @apartment_pinned = true
      end

      def apartment_pinned?
        return true if @apartment_pinned == true
        return false unless superclass.respond_to?(:apartment_pinned?)

        superclass.apartment_pinned?
      end

      # Whether this model has an explicit self.table_name = assignment
      # (as opposed to Rails' lazy convention computation). Returns false
      # if the explicit value matches what convention would produce, since
      # the convention path handles that case correctly.
      # NOTE: compute_table_name is a private Rails API; tested against
      # Rails main as a canary in CI.
      def apartment_explicit_table_name?
        return false unless instance_variable_defined?(:@table_name)

        instance_variable_get(:@table_name) != send(:compute_table_name)
      end

      # Whether process_pinned_model has already run for this class.
      def apartment_pinned_processed?
        @apartment_pinned_processed == true
      end

      # Record that qualification has been applied, and what path was used.
      # Called by qualify_pinned_table_name (adapters) after mutations succeed,
      # or by process_pinned_model after establish_connection on separate-pool path.
      def apartment_mark_processed!(path = nil, original_value = nil)
        @apartment_pinned_processed = true
        @apartment_qualification_path = path
        case path
        when :explicit then @apartment_original_table_name = original_value
        when :convention then @apartment_original_table_name_prefix = original_value
        end
      end

      # Undo table name qualification and clear tracking state.
      # Convention path: restore original prefix so reset_table_name recomputes.
      # Explicit path: restore the original table_name that was overwritten.
      # nil path: separate-pool models — no table name changes to undo.
      def apartment_restore!
        return unless @apartment_pinned_processed

        case @apartment_qualification_path
        when :convention
          self.table_name_prefix = @apartment_original_table_name_prefix || ''
          reset_table_name
        when :explicit
          self.table_name = @apartment_original_table_name if @apartment_original_table_name
        when nil then nil
        else
          warn "[Apartment] #{name}: unexpected qualification_path #{@apartment_qualification_path.inspect}"
        end

        @apartment_pinned_processed = nil
        @apartment_qualification_path = nil
        @apartment_original_table_name = nil
        @apartment_original_table_name_prefix = nil
      end

      private

      # Register a one-shot TracePoint(:end) that fires after the class body
      # closes. Only :end is used — :b_return fires for ALL block returns in
      # class context (each, tap, include hooks) and would trigger prematurely.
      # :raise is not used — rescued raises still produce :end, and unconditional
      # disable would prevent processing on successful load.
      # MRI verified: :end fires for source-parsed class/module keywords even
      # when the body raises (event order [:raise, :end]).
      # For Class.new { }, :end does not fire; call process_pinned_model explicitly.
      # See docs/designs/v4-deferred-pin-tenant-processing.md.
      def apartment_defer_processing!
        klass = self
        trace = TracePoint.new(:end) do |t|
          if t.self == klass
            trace.disable
            begin
              Apartment.process_pinned_model(klass)
            rescue StandardError => e
              warn '[Apartment] Failed to process pinned model ' \
                   "#{klass.name || klass.inspect}: #{e.class}: #{e.message}"
              raise
            end
          end
        end
        trace.enable(target_thread: Thread.current)
      end
    end
  end
end
# rubocop:enable ThreadSafety/ClassInstanceVariable
