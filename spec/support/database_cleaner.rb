# frozen_string_literal: true

# spec/support/database_cleaner.rb

require 'database_cleaner-active_record'

RSpec.configure do |config|
  config.before(:suite) do
    DatabaseCleaner.clean_with(:truncation)
    DatabaseCleaner.strategy = :truncation
  rescue ActiveRecord::ConnectionNotEstablished
    # No database connection - do nothing
  end

  config.before do
    DatabaseCleaner.start
  rescue ActiveRecord::ConnectionNotEstablished
    # No database connection - do nothing
  end

  config.after do
    DatabaseCleaner.clean
  rescue ActiveRecord::ConnectionNotEstablished
    # No database connection - do nothing
  end
end
