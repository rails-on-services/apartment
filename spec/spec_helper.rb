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
require_relative 'support/rails_stub'

RSpec.configure do |config|
  config.after do
    Apartment.clear_config
    Apartment::Current.reset
  end

  # Apartment.pinned_models is a process-lifetime registry — clear_config keeps
  # it (see spec/CLAUDE.md). Example groups whose assertions depend on exactly
  # which models are pinned tag themselves :isolate_pinned_models for a clean
  # registry per example.
  config.before(:each, :isolate_pinned_models) do
    Apartment.pinned_models.clear
  end
end
