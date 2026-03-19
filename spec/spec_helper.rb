# frozen_string_literal: true

require 'bundler/setup'
require 'apartment'

RSpec.configure do |config|
  config.after(:each) do
    Apartment.clear_config
    Apartment::Current.reset
  end
end
