# frozen_string_literal: true

module RuboCop
  module Cop
    module Apartment
      # Bans direct assignment to Apartment::Current attributes. Application code
      # must change tenant context through the block-form switch, which guarantees
      # restore via ensure.
      #
      # @example
      #   # bad
      #   Apartment::Current.tenant = 'acme'
      #
      #   # good
      #   Apartment::Tenant.switch('acme') { ... }
      class NoDirectCurrentWrite < Base
        MSG = 'Do not write `Apartment::Current.%<attr>s` directly; use the ' \
              'block-form `Apartment::Tenant.switch(tenant) { ... }`.'

        # @!method current_attr_write?(node)
        def_node_matcher :current_attr_write?, <<~PATTERN
          (send (const (const {nil? cbase} :Apartment) :Current) {:tenant= :previous_tenant=} _)
        PATTERN

        def on_send(node)
          return unless current_attr_write?(node)

          attr = node.method_name.to_s.delete_suffix('=')
          # Highlight the attribute selector (`tenant` / `previous_tenant`), not the
          # whole assignment — stable range, independent of the RHS and any cbase.
          add_offense(node.loc.selector, message: format(MSG, attr: attr))
        end
      end
    end
  end
end
