# frozen_string_literal: true

# rubocop:disable Style/ClassAndModuleChildren

# NOTE: This patch is meant to remove any schema_prefix appart from the ones for
# excluded models. The schema_prefix would be resolved by apartment's setting
# of search path
module Apartment::PostgreSqlAdapterPatch
  def default_sequence_name(table, _column)
    res = super

    # for JDBC driver, if rescued in super_method, trim leading and trailing quotes
    res.delete!('"') if defined?(JRUBY_VERSION)

    schema_prefix = "#{sequence_schema(res)}."

    # NOTE: Excluded models should always access the sequence from the default
    # tenant schema
    if excluded_model?(table)
      default_tenant_prefix = "#{Apartment::Tenant.default_tenant}."

      res.sub!(schema_prefix, default_tenant_prefix) if schema_prefix != default_tenant_prefix
      return res
    end

    res.delete_prefix!(schema_prefix) if res&.starts_with?(schema_prefix)

    res
  end

  private

  def sequence_schema(sequence_name)
    current = Apartment::Tenant.current
    return current unless current.is_a?(Array)

    current.find { |schema| sequence_name.starts_with?("#{schema}.") }
  end

  def excluded_model?(table)
    Apartment.excluded_models.any? { |m| m.constantize.table_name == table }
  end
end

require 'active_record/connection_adapters/postgresql_adapter'

# NOTE: inject this into postgresql adapters
class ActiveRecord::ConnectionAdapters::PostgreSQLAdapter
  include Apartment::PostgreSqlAdapterPatch
end
# rubocop:enable Style/ClassAndModuleChildren
