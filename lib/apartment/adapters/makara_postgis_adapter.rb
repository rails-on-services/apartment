# frozen_string_literal: true

require 'active_record/connection_adapters/makara_postgresql_adapter'
require 'capabilities/apartment_manager'

module Apartment
  module Tenant
    def self.makara_postgis_adapter(config)
      Adapters::MakaraPostgisAdapter.new(config)
    end
  end
end

module Apartment
  module Adapters
    # Separate Adapter for Postgresql when using schemas
    class MakaraPostgisAdapter < ActiveRecord::ConnectionAdapters::MakaraPostgreSQLAdapter
      include ActiveSupport::Callbacks
      include Capabilities::ApartmentManager

      define_callbacks :create, :switch

      attr_writer :default_tenant
    end
  end
end
