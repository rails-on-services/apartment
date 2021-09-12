# frozen_string_literal: true

module Apartment
  module Model
    extend ActiveSupport::Concern

    module ClassMethods
      def sequence_name
        current_sequence_name = super
        return current_sequence_name if sequence_name_matches_tenant?(current_sequence_name)

        connection.default_sequence_name(table_name, primary_key)
      end

      # NOTE: key can either be an array of symbols or a single value.
      # E.g. If we run the following query:
      # `Setting.find_by(key: 'something', value: 'amazing')` key will have an array of symbols: `[:key, :something]`
      # while if we run:
      # `Setting.find(10)` key will have the value 'id'
      def cached_find_by_statement(key, &block)
        # Modifying the cache key to have a reference to the current tenant,
        # so the cached statement is referring only to the tenant in which we've
        # executed this
        cache_key = if key.is_a? String
                      "#{Apartment::Tenant.current}_#{key}"
                    else
                      # NOTE: In Rails 6.0.4 we start receiving an ActiveRecord::Reflection::BelongsToReflection
                      # as the key, which wouldn't work well with an array.
                      [Apartment::Tenant.current] + Array.wrap(key)
                    end
        cache = @find_by_statement_cache[connection.prepared_statements]
        cache.compute_if_absent(cache_key) { ActiveRecord::StatementCache.create(connection, &block) }
      end

      def sequence_name_matches_tenant?(sequence_name)
        schema_prefix = "#{Apartment::Tenant.current}."
        sequence_name&.starts_with?(schema_prefix) &&
          Apartment.excluded_models.none? { |m| m.constantize.table_name == table_name }
      end
    end
  end
end
