# frozen_string_literal: true

require File.expand_path('boot', __dir__)

require 'active_model/railtie'
require 'active_record/railtie'
require 'action_controller/railtie'

Bundler.require
require 'apartment'
# spec_helper.rb requires 'apartment' before any Rails is loaded, so the
# conditional `require 'apartment/railtie' if defined?(Rails::Railtie)` in
# lib/apartment.rb is missed. Load it explicitly — the Rails railties above
# are already required, and this runs before initialize!, so Apartment's
# initializers (the elevator middleware insertion) register in time.
require 'apartment/railtie'

module Dummy
  class Application < Rails::Application
    config.load_defaults(Rails::VERSION::STRING.to_f)
    config.eager_load = false
    config.encoding = 'utf-8'
    config.filter_parameters += [:password]

    # v4 Railtie handles middleware insertion and Apartment.activate!
    # No manual middleware.use needed.
  end
end
