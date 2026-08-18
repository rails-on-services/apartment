# frozen_string_literal: true

module Apartment
  # Prebuilt tenant privilege policies. Apartment issues no grants of its own; a
  # policy runs only because an adopter configured one.
  module Privileges
    module_function

    # A policy granting an app role the privileges a routed tenant normally needs.
    #
    # Returns a callable rather than executing, so it can be assigned directly to
    # config.tenant_privilege_policy and so it owns its own phase mapping. As an
    # immediate call it would have forced every adopter to re-derive which
    # statements belong before the schema import and which after; that mapping is
    # exactly the knowledge this helper exists to carry.
    #
    #   c.tenant_privilege_policy = Apartment::Privileges.standard(grant_to: 'app_user')
    #
    # Composable, because it is just a callable:
    #
    #   standard = Apartment::Privileges.standard(grant_to: 'app_user')
    #   c.tenant_privilege_policy = lambda { |ctx|
    #     standard.call(ctx)
    #     ctx.connection.execute('...') if ctx.after_schema_load?
    #   }
    #
    # @param grant_to [String, Array<String>] role names, or MySQL accounts
    # @param include_functions [Boolean] PostgreSQL only; the EXECUTE ON FUNCTIONS
    #   default-privileges rule. MySQL has no equivalent and ignores it.
    # @return [Proc] takes one Privileges::Context, returns the statements executed
    def standard(grant_to:, include_functions: true)
      roles = Array(grant_to)
      if roles.empty? || !roles.all?(String)
        raise(Apartment::ConfigurationError,
              "grant_to must be a String or a non-empty Array of Strings, got: #{grant_to.inspect}")
      end

      lambda do |ctx|
        statements = Apartment.adapter.standard_privilege_statements(
          ctx, grant_to: roles, include_functions: include_functions
        )
        statements.each { |sql| ctx.connection.execute(sql) }
      end
    end
  end
end
