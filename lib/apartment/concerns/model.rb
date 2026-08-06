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
      # Idempotent per class: a second call on the same class is a no-op.
      #
      # Deliberately keyed on this class's own flag, NOT on apartment_pinned?
      # (which walks the superclass chain). A subclass of a pinned model that
      # declares its own table has to be registered and qualified on its own
      # merits — the parent's qualification cannot reach a different table.
      # Keying on the chain made that call accept-and-do-nothing, which is the
      # wrong answer even for a shape apps should avoid: an API call must
      # either work or be absent, never silently no-op. Subclasses that share
      # the parent's table still need nothing, and are skipped at
      # qualification time rather than here (see
      # AbstractAdapter#inherits_pinned_table?).
      def pin_tenant
        unless is_a?(Class) && self < ActiveRecord::Base
          raise(ArgumentError, "pin_tenant can only be called on ActiveRecord model classes, got #{inspect}")
        end
        return if @apartment_pinned

        @apartment_pinned = true
        Apartment.register_pinned_model(self)

        return unless Apartment.activated?

        # Defer processing until the class body closes via TracePoint(:end),
        # so self.table_name and other declarations are visible.
        # For Class.new { } (anonymous classes), :end does not fire.
        if name.nil?
          warn '[Apartment] pin_tenant on anonymous class (Class.new): TracePoint(:end) ' \
               'will not fire. Call Apartment.process_pinned_model(klass) explicitly after the block.'
          return
        end

        apartment_defer_processing!
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

      # Whether this model's current table_name would survive a recomputation
      # — i.e. whether Rails' convention machinery reproduces the value now
      # cached in @table_name. False means convention rebuilds it exactly, so
      # qualification can be undone by discarding the override; true means the
      # name must be saved verbatim and restored verbatim.
      #
      # This answers a *restore* question. It is deliberately NOT a
      # qualification discriminator: a table_name that matches convention is no
      # evidence that setting table_name_prefix would qualify the model. Rails
      # ignores the prefix outright for any class that is not its own
      # base_class (compute_table_name returns base_class.table_name verbatim),
      # and full_table_name_prefix prefers a module parent's prefix over the
      # class's own. Qualification therefore always assigns table_name
      # directly — see AbstractAdapter#qualify_pinned_table_name.
      #
      # NOTE: compute_table_name is a private Rails API; tested against
      # Rails main as a canary in CI.
      def apartment_explicit_table_name?
        return false unless instance_variable_defined?(:@table_name)

        instance_variable_get(:@table_name) != send(:compute_table_name)
      end

      # Descendants that reach their table name through this class rather than
      # declaring one of their own, and have already memoized it.
      #
      # Rails memoizes @table_name per class on first read and never
      # invalidates a descendant's copy when an ancestor's name or prefix
      # changes. Anything touching a descendant's table_name before
      # qualification runs — an initializer, a gem, a route constraint, a
      # descendants sweep — freezes the pre-qualification name, and the model
      # then resolves to the wrong tenant's table for the life of the process.
      #
      # MUST be called BEFORE the ancestor is mutated: afterwards
      # apartment_explicit_table_name? can no longer distinguish a stale memo
      # from a genuine declaration, since the ancestor's change has moved what
      # convention computes. Descendants without a memo are omitted — they
      # compute lazily and will pick the new value up on their own.
      def apartment_descendants_inheriting_table_name
        return [] unless respond_to?(:descendants)

        stale = descendants.select do |sub|
          sub.instance_variable_defined?(:@table_name) &&
            sub.respond_to?(:apartment_inherited_table_name) &&
            sub.instance_variable_get(:@table_name) == sub.apartment_inherited_table_name
        rescue StandardError
          # Rails' naming machinery raises on shapes we do not control (an
          # anonymous class has no model_name). Skip rather than guess.
          false
        end

        # Reset an intermediate before anything beneath it: reset_table_name on
        # a class under an abstract parent reads superclass.table_name — the
        # memo, not base_class — so a grandchild reset first would re-freeze its
        # parent's stale value. ActiveSupport's descendants happens to be
        # ancestor-first today, but that ordering is undocumented.
        stale.sort_by { |sub| sub.ancestors.size }
      end

      # What Rails' own reset_table_name would recompute for this class right
      # now. Mirrors ActiveRecord::ModelSchema#reset_table_name deliberately.
      #
      # NOT compute_table_name: the two disagree for a class whose superclass
      # is abstract. reset_table_name prefers `superclass.table_name`, while
      # compute_table_name treats such a class as its own base_class and builds
      # from its own model_name. So a concrete class under an abstract
      # intermediate that carries a table (an abstract class sandwiched under a
      # concrete pinned parent) inherits `foos` but computes `gkids` — and
      # keying on compute_table_name misreads that inherited name as an
      # explicit declaration, skipping the resync and leaving the model on the
      # tenant's table.
      def apartment_inherited_table_name
        if abstract_class?
          superclass.table_name
        elsif superclass.abstract_class?
          superclass.table_name || send(:compute_table_name)
        else
          send(:compute_table_name)
        end
      end

      # Recompute the table name of each descendant captured above, now that
      # this class has changed. reset_table_name goes through Rails' own
      # table_name= setter, so the derived @quoted_table_name and @arel_table
      # caches are cleared with it.
      def apartment_resync_descendant_table_names!(subclasses)
        subclasses.each do |sub|
          sub.reset_table_name
        rescue StandardError => e
          warn "[Apartment] could not reset table name for #{sub.name || sub.inspect}: " \
               "#{e.class}: #{e.message}"
        end
      end

      # Whether process_pinned_model has already run for this class.
      def apartment_pinned_processed?
        @apartment_pinned_processed == true
      end

      # Record that qualification has been applied, and how it must be undone.
      # Called by qualify_pinned_table_name (adapters) after mutations succeed,
      # or by process_pinned_model after establish_connection on separate-pool path.
      #
      # :computed — the pre-qualification name was reproducible by convention;
      #   restore by discarding the override and recomputing.
      # :explicit — the name was assigned in a way convention cannot rebuild;
      #   +original_value+ is that name, restored verbatim.
      # :prefix — an abstract base, qualified by broadcasting through
      #   table_name_prefix to the descendants that inherit its pin;
      #   +original_value+ is the prefix the app had set.
      # nil — separate-pool models; nothing to undo.
      def apartment_mark_processed!(path = nil, original_value = nil)
        @apartment_pinned_processed = true
        @apartment_qualification_path = path
        case path
        when :explicit then @apartment_original_table_name = original_value
        when :prefix then @apartment_original_table_name_prefix = original_value
        end
      end

      # Undo table name qualification and clear tracking state.
      def apartment_restore!
        return unless @apartment_pinned_processed

        inheriting = apartment_descendants_inheriting_table_name
        apartment_undo_qualification!
        apartment_resync_descendant_table_names!(inheriting)

        @apartment_pinned_processed = nil
        @apartment_qualification_path = nil
        @apartment_original_table_name = nil
        @apartment_original_table_name_prefix = nil
      end

      private

      # Reverse whichever mutation qualify_pinned_table_name applied.
      def apartment_undo_qualification!
        case @apartment_qualification_path
        when :computed then apartment_recompute_table_name!
        when :explicit then apartment_restore_table_name!
        when :prefix then self.table_name_prefix = @apartment_original_table_name_prefix || ''
        when nil then nil
        else
          warn "[Apartment] #{name}: unexpected qualification_path #{@apartment_qualification_path.inspect}"
        end
      end

      # Drop the qualified override and recompute from convention. The ivar is
      # removed first so nothing can keep the qualified value; the recompute
      # then runs through Rails' table_name= setter, which also clears the
      # derived @quoted_table_name and @arel_table caches.
      def apartment_recompute_table_name!
        remove_instance_variable(:@table_name) if instance_variable_defined?(:@table_name)
        reset_table_name
      end

      def apartment_restore_table_name!
        self.table_name = @apartment_original_table_name if @apartment_original_table_name
      end

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
