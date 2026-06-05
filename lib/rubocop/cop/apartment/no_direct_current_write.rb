# frozen_string_literal: true

module RuboCop
  module Cop
    module Apartment
      # Bans direct assignment to Apartment::Current attributes. Application code
      # must change tenant context through the block-form switch, which guarantees
      # restore via ensure.
      #
      # Covers plain assignment (`=`) and operator assignment (`||=`, `&&=`, `+=`).
      # Known syntactic limitations (deliberately not chased — they signal
      # deliberate evasion and are out of scope for a lint nudge): multiple
      # assignment (`a, Apartment::Current.tenant = ...`), safe navigation
      # (`Apartment::Current&.tenant = ...`), dynamic dispatch
      # (`Apartment::Current.public_send(:tenant=, ...)`), bulk mutators
      # (`Apartment::Current.set(...)` / `.reset`), and aliased receivers.
      #
      # @example
      #   # bad
      #   Apartment::Current.tenant = 'acme'
      #   Apartment::Current.tenant ||= 'acme'
      #
      #   # good
      #   Apartment::Tenant.switch('acme') { ... }
      class NoDirectCurrentWrite < Base
        MSG = 'Do not write `Apartment::Current.%<attr>s` directly; use the ' \
              'block-form `Apartment::Tenant.switch(tenant) { ... }`.'

        # Only invoke on_send for these setters — keeps the cop off the hot path
        # (RuboCop would otherwise call on_send for every method call linted).
        RESTRICT_ON_SEND = %i[tenant= previous_tenant=].freeze

        # @!method current_attr_write?(node)
        def_node_matcher :current_attr_write?, <<~PATTERN
          (send (const (const {nil? cbase} :Apartment) :Current) {:tenant= :previous_tenant=} _)
        PATTERN

        # The reader-shaped LHS of an operator-assignment (`tenant ||= x` parses as
        # an or_asgn around `(send recv :tenant)`, not a `:tenant=` send).
        # @!method current_attr_lhs?(node)
        def_node_matcher :current_attr_lhs?, <<~PATTERN
          (send (const (const {nil? cbase} :Apartment) :Current) {:tenant :previous_tenant})
        PATTERN

        def on_send(node)
          return unless current_attr_write?(node)

          register(node, node.method_name.to_s.delete_suffix('='))
        end

        # `||=` and `&&=` are or_asgn / and_asgn; `+=` etc. are op_asgn. The LHS is
        # always the first child (a reader send). RESTRICT_ON_SEND does not apply to
        # these callbacks, so the matcher does the filtering.
        def on_or_asgn(node)
          check_op_assign(node.children.first)
        end
        alias on_and_asgn on_or_asgn

        def on_op_asgn(node)
          check_op_assign(node.children.first)
        end

        private

        def check_op_assign(lhs)
          return unless current_attr_lhs?(lhs)

          register(lhs, lhs.method_name.to_s)
        end

        # Highlight the attribute selector (`tenant` / `previous_tenant`), not the
        # whole assignment — stable range, independent of the RHS and any cbase.
        def register(node, attr)
          add_offense(node.loc.selector, message: format(MSG, attr: attr))
        end
      end
    end
  end
end
