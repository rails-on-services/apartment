# frozen_string_literal: true

module RuboCop
  module Cop
    module Apartment
      # Nudges callers away from Apartment::Tenant.switch! toward the block-form
      # switch, which restores context via ensure. reset is intentionally not
      # flagged (it is the sanctioned unguarded path back to the default tenant).
      #
      # @example
      #   # bad
      #   Apartment::Tenant.switch!('acme')
      #
      #   # good
      #   Apartment::Tenant.switch('acme') { ... }
      class PreferBlockSwitch < Base
        MSG = 'Use the block-form `Apartment::Tenant.switch(tenant) { ... }` ' \
              'instead of `switch!`.'

        # Only invoke on_send for switch! — keeps the cop off the hot path
        # (RuboCop would otherwise call on_send for every method call linted).
        RESTRICT_ON_SEND = %i[switch!].freeze

        # @!method tenant_bang_switch?(node)
        def_node_matcher :tenant_bang_switch?, <<~PATTERN
          (send (const (const {nil? cbase} :Apartment) :Tenant) :switch! ...)
        PATTERN

        def on_send(node)
          return unless tenant_bang_switch?(node)

          # Highlight the `switch!` selector — stable range regardless of receiver
          # prefix or arguments.
          add_offense(node.loc.selector)
        end
      end
    end
  end
end
