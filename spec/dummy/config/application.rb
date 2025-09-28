# frozen_string_literal: true

require 'rails'
require 'active_model/railtie'
require 'active_record/railtie'

module Dummy
  class Application < Rails::Application
    config.root = File.expand_path('..', __dir__)
    config.load_defaults(Rails::VERSION::STRING.to_f)
    # Do not eager load code on boot. This avoids loading your whole application
    # just for the purpose of running a single test.
    config.eager_load = false
    # The test environment is used exclusively to run your application's
    # test suite. You never need to work with it otherwise. Remember that
    # your test database is "scratch space" for the test suite and is wiped
    # and recreated between test runs. Don't rely on the data there!
    config.cache_classes = true
    config.active_support.deprecation = :log
    config.secret_key_base = 'test'

    logger           = ActiveSupport::Logger.new($stdout)
    logger.formatter = config.log_formatter
    config.logger    = ActiveSupport::TaggedLogging.new(logger)
  end
end
