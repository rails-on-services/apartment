# frozen_string_literal: true

require 'bundler/setup'

# Load real ActiveRecord when available (appraisal gemfiles include it).
# This must happen before any spec file defines an AR stub.
begin
  require 'active_record'
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
