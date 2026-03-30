# frozen_string_literal: true

if ENV['COVERAGE']
  require 'simplecov'
  SimpleCov.start do
    add_filter '/spec/'
    add_filter '/gemfiles/'
    add_group 'Adapters', 'lib/apartment/adapters'
    add_group 'Patches', 'lib/apartment/patches'
    add_group 'Config', 'lib/apartment/configs'
    add_group 'Core', 'lib/apartment'
    minimum_coverage 80
  end
end

require 'bundler/setup'

# Load real ActiveRecord when available (appraisal gemfiles include it).
# This must happen before any spec file defines an AR stub.
begin
  require('active_record')
rescue LoadError
  # Not available — specs that need it will skip or use stubs.
end

require 'apartment'

RSpec.configure do |config|
  config.after do
    Apartment.clear_config
    Apartment::Current.reset
  end
end
