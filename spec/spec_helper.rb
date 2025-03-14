# frozen_string_literal: true

require 'bundler/setup'
Bundler.require(:default, :test)

if ENV['CI'].eql?('true') # ENV['CI'] defined as true by GitHub Actions
  require 'simplecov'
  require 'simplecov_json_formatter'

  SimpleCov.formatter = SimpleCov::Formatter::JSONFormatter

  SimpleCov.start do
    add_filter '/spec/'

    # add_group 'Adapter', 'lib/apartment/adapters'
    # add_group 'Elevators', 'lib/apartment/elevators'
    # add_group 'Core', 'lib/apartment'
  end
end

require_relative '../lib/apartment' # Load the Apartment gem

# Include any support files or helpers
# Dir["#{File.dirname(__FILE__)}/support/**/*.rb"].each { |f| require f }

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.filter_run_when_matching(:focus)
end

# Load shared examples
# Dir["#{File.dirname(__FILE__)}/examples/**/*.rb"].each { |f| require f }
