# frozen_string_literal: true

# lib/apartment/logger.rb

require 'active_support/logger'
require 'active_support/tagged_logging'

module Apartment
  class Logger
    class << self
      attr_writer :logger # rubocop:disable ThreadSafety/ClassAndModuleAttributes

      # Returns the logger for Apartment, defaulting to Rails.logger if available.
      def logger
        @logger ||= if defined?(Rails.logger) # rubocop:disable ThreadSafety/ClassInstanceVariable
                      ActiveSupport::TaggedLogging.new(Rails.logger)
                    else
                      ActiveSupport::TaggedLogging.new(ActiveSupport::Logger.new($stdout))
                    end
      end

      # Logs a debug message with the Apartment tag.
      def debug(...)
        logger.tagged('Apartment') { logger.debug(...) }
      end

      # Logs an info message with the Apartment tag.
      def info(...)
        logger.tagged('Apartment') { logger.info(...) }
      end

      # Logs a warning message with the Apartment tag.
      def warn(...)
        logger.tagged('Apartment') { logger.warn(...) }
      end

      # Logs an error message with the Apartment tag.
      def error(...)
        logger.tagged('Apartment') { logger.error(...) }
      end
    end
  end
end
