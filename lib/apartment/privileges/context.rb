# frozen_string_literal: true

module Apartment
  module Privileges
    # What a tenant_privilege_policy receives. One instance per phase.
    #
    # Deliberately not Data.define, though Data is house style for value objects
    # (Migrator::Result, PoolObserver::Sample). This is not a value object: it
    # carries a live connection, which is mutable and meaningless outside the
    # invocation, and Data would give it value equality, hashing and positional
    # decomposition as public semantics. Data also cannot deliver the additive-only
    # promise below — appending a member adds a required positional argument and a
    # required keyword to .new, and Data responds to #deconstruct, so an adopter
    # constructing a context in a unit test or destructuring it positionally would
    # break on a minor release.
    #
    # Additive-only: new fields arrive as keyword arguments with defaults, and
    # unknown keywords are ignored, so a policy reading attributes off a context
    # Apartment handed it keeps working. Construction is the gem's business.
    class Context
      attr_reader :tenant, :container_name, :connection, :db_role, :phase

      # @param tenant [String] the tenant name as Apartment knows it
      # @param container_name [String] the physical schema or database to address
      # @param connection [ActiveRecord::ConnectionAdapters::AbstractAdapter]
      #   valid for this invocation only; do not retain it
      # @param db_role [String, nil] the executing database role, nil where the
      #   engine has no role system
      # @param phase [Symbol] :before_schema_load or :after_schema_load
      def initialize(tenant:, container_name:, connection:, db_role:, phase:, **)
        @tenant = tenant
        @container_name = container_name
        @connection = connection
        @db_role = db_role
        @phase = phase
        freeze
      end

      def before_schema_load? = phase == :before_schema_load
      def after_schema_load? = phase == :after_schema_load

      # The value every policy needs. Provided so that copied example code quotes
      # by default rather than interpolating a raw identifier.
      def quoted_container = connection.quote_table_name(container_name)
    end
  end
end
