# frozen_string_literal: true

require 'active_record/log_subscriber'

module Apartment
  # Custom Log subscriber to include database name and schema name in sql logs
  class LogSubscriber < ActiveRecord::LogSubscriber
    # NOTE: for some reason, if the method definition is not here, then the custom debug method is not called
    # rubocop:disable Lint/UselessMethodDefinition
    def sql(event)
      super
    end
    # rubocop:enable Lint/UselessMethodDefinition

    private

    def debug(progname = nil, &blk)
      progname = "  #{apartment_log}#{progname}" unless progname.nil?

      super
    end

    def apartment_log
      database = color("[#{database_name}] ", ActiveSupport::LogSubscriber::MAGENTA, bold: true)
      schema = current_search_path
      schema = color("[#{schema.tr('"', '')}] ", ActiveSupport::LogSubscriber::YELLOW, bold: true) unless schema.nil?
      "#{database}#{schema}"
    end

    def current_search_path
      if Apartment.connection.respond_to?(:schema_search_path)
        Apartment.connection.schema_search_path
      else
        Apartment::Tenant.current # all others
      end
    end

    def database_name
      db_name = Apartment.connection.raw_connection.try(:db) # PostgreSQL, PostGIS
      db_name ||= Apartment.connection.raw_connection.try(:query_options)&.dig(:database) # Mysql
      db_name ||= Apartment.connection.current_database # Failover
      db_name
    end
  end
end
