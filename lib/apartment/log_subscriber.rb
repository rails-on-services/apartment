
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
      Apartment.with_connection do |conn|
        conn.respond_to?(:schema_search_path) ? conn.schema_search_path : Apartment::Tenant.current
      end
    end

    def database_name
      Apartment.with_connection do |conn|
        case conn.adapter_name
        when "PostgreSQL", "PostGIS", "Mysql2"
          conn.current_database
        when "SQLite"
          conn.connection_db_config.database # returns path or memory
        else
          raise NotImplementedError, "Adapter #{conn.adapter_name} unsupported for logging"
        end
      end
    end
  end
end
