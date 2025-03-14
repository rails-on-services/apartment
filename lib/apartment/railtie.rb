# frozen_string_literal: true

# lib/apartment/railtie.rb

require 'rails'

module Apartment
  class Railtie < ::Rails::Railtie
    initializer 'apartment.initialize_connection_handler', after: 'active_record.initialize_database' do |app|
      app.config.to_prepare do
        # This will be re-run on each code reload in development.
        Apartment.connection_class.default_connection_handler = Apartment::ConnectionAdapters::ConnectionHandler.new
      end
    end
  end
end
