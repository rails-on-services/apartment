# frozen_string_literal: true

# spec/rails_helper.rb

require 'spec_helper'
# Set up the Rails environment for testing
ENV['RAILS_ENV'] ||= 'test'

require_relative 'dummy/config/environment' # Load the Dummy app

require 'rspec/rails' # Load RSpec-Rails

RSpec.configure do |config|
  # config.filter_run_excluding(database: lambda { |engine|
  #   case ENV.fetch('DATABASE_ENGINE', nil)
  #   when 'mysql'
  #     %i[sqlite postgresql].include?(engine)
  #   when 'sqlite'
  #     %i[mysql postgresql].include?(engine)
  #   when 'postgresql'
  #     %i[mysql sqlite].include?(engine)
  #   else
  #     false
  #   end
  # })
end
