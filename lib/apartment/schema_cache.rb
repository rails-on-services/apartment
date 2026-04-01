# frozen_string_literal: true

require 'pathname'

module Apartment
  module SchemaCache
    module_function

    def dump(tenant)
      path = cache_path_for(tenant)
      Apartment::Tenant.switch(tenant) do
        ActiveRecord::Base.connection.schema_cache.dump_to(path)
      end
      path
    end

    def dump_all
      Apartment.config.tenants_provider.call.map { |t| dump(t) }
    end

    def cache_path_for(tenant)
      base = defined?(Rails) && Rails.root ? Rails.root.join('db') : Pathname.new('db')
      base.join("schema_cache_#{tenant}.yml").to_s
    end
  end
end
