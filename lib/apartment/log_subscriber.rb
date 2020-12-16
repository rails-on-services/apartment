# frozen_string_literal: true

module Apartment
  class LogSubscriber < ActiveRecord::LogSubscriber
    def sql(event)
      super(event)
    end

    private

    def debug(progname = nil, &block)
      progname = "  #{apartment_log}#{progname}" unless progname.nil?

      super(progname, &block)
    end

    def apartment_log
      database = color("[#{Apartment.connection.current_database}] ", ActiveSupport::LogSubscriber::MAGENTA, true)
      schema = nil
      unless Apartment.connection.schema_search_path.nil?
        schema = color("[#{Apartment.connection.schema_search_path.tr('"', '')}] ",
                       ActiveSupport::LogSubscriber::YELLOW, true)
      end
      "#{database}#{schema}"
    end
  end
end
