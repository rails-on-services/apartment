# frozen_string_literal: true

# lib/apartment/railtie.rb

require 'rails'

module Apartment
  class Railtie < ::Rails::Railtie
    initializer 'apartment.register_db_config_handler', before: 'active_record.initialize_database' do |app|
      require 'active_record/database_configurations'
      app.config.before_configuration do
        Logger.debug('apartment.register_db_config_handler')
        ActiveRecord::DatabaseConfigurations.register_db_config_handler do |env_name, name, url, config|
          if url
            Apartment::DatabaseConfigurations::UrlConfig.new(
              env_name, name, url, config,
              Apartment::Tenant.current
            )
          else
            Apartment::DatabaseConfigurations::HashConfig.new(
              env_name, name, config,
              Apartment::Tenant.current
            )
          end
        end
      end
    end
    initializer 'apartment.initialize_connection_handler', after: 'active_record.initialize_database' do |app|
      app.config.to_prepare do
        Logger.debug('apartment.initialize_connection_handler')
        Apartment.connection_class.default_connection_handler = Apartment::ConnectionAdapters::ConnectionHandler.new
      end
    end
  end
end
