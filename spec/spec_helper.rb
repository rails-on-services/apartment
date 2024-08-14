# frozen_string_literal: true

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

begin
  require 'pry'
  # rubocop:disable Lint/ConstantDefinitionInBlock
  silence_warnings { IRB = Pry }
  # rubocop:enable Lint/ConstantDefinitionInBlock
rescue LoadError
  nil
end

ActionMailer::Base.delivery_method = :test
ActionMailer::Base.perform_deliveries = true
ActionMailer::Base.default_url_options[:host] = 'test.com'

Rails.backtrace_cleaner.remove_silencers!

# Load support files
Dir["#{File.dirname(__FILE__)}/support/**/*.rb"].sort.each { |f| require f }

RSpec.configure do |config|
  config.include Apartment::Spec::Setup

  # Somewhat brutal hack so that rails 4 postgres extensions don't modify this file
  # rubocop:disable RSpec/BeforeAfterAll
  config.after(:all) do
    `git checkout -- spec/dummy/db/schema.rb`
  end
  # rubocop:enable RSpec/BeforeAfterAll

  # rspec-rails 3 will no longer automatically infer an example group's spec type
  # from the file location. You can explicitly opt-in to the feature using this
  # config option.
  # To explicitly tag specs without using automatic inference, set the `:type`
  # metadata manually:
  #
  #     describe ThingsController, :type => :controller do
  #       # Equivalent to being in spec/controllers
  #     end
  config.infer_spec_type_from_file_location!
end

# Load shared examples, must happen after configure for RSpec 3
Dir["#{File.dirname(__FILE__)}/examples/**/*.rb"].sort.each { |f| require f }
