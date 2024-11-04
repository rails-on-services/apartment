# frozen_string_literal: true

if ENV['CI'].eql?('true') # ENV['CI'] defined as true by GitHub Actions
  require 'simplecov'
  require 'simplecov_json_formatter'

  SimpleCov.formatter = SimpleCov::Formatter::JSONFormatter

  SimpleCov.start do
    add_filter '/spec/'

    add_group 'Adapter', 'lib/apartment/adapters'
    add_group 'Elevators', 'lib/apartment/elevators'
    add_group 'Core', 'lib/apartment'
  end
end

$LOAD_PATH.unshift(File.dirname(__FILE__))

# Configure Rails Environment
ENV['RAILS_ENV'] = 'test'

require File.expand_path('dummy/config/environment.rb', __dir__)

# Loading dummy applications affects table_name of each excluded models
# defined in `spec/dummy/config/initializers/apartment.rb`.
# To make them pristine, we need to execute below lines.
Apartment.excluded_models.each do |model|
  klass = model.constantize

  klass.remove_connection
  klass.connection_handler.clear_all_connections!
  klass.reset_table_name
end

require 'rspec/rails'

ActionMailer::Base.delivery_method = :test
ActionMailer::Base.perform_deliveries = true
ActionMailer::Base.default_url_options[:host] = 'test.com'

Rails.backtrace_cleaner.remove_silencers!

# Load support files
Dir["#{File.dirname(__FILE__)}/support/**/*.rb"].each { |f| require f }

RSpec.configure do |config|
  config.include(Apartment::Spec::Setup)

  # Somewhat brutal hack so that rails 4 postgres extensions don't modify this file
  # rubocop:disable RSpec/BeforeAfterAll
  config.after(:all) do
    `git checkout -- spec/dummy/db/schema.rb`
  end
  # rubocop:enable RSpec/BeforeAfterAll

  config.filter_run_excluding(database: lambda { |engine|
    case ENV.fetch('DATABASE_ENGINE', nil)
    when 'mysql'
      %i[sqlite postgresql].include?(engine)
    when 'sqlite'
      %i[mysql postgresql].include?(engine)
    when 'postgresql'
      %i[mysql sqlite].include?(engine)
    else
      false
    end
  })

  config.include(MigrationHelpers, type: :migration)
end

# Load shared examples, must happen after configure for RSpec 3
Dir["#{File.dirname(__FILE__)}/examples/**/*.rb"].each { |f| require f }
