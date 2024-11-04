# frozen_string_literal: true

# spec/support/faker_config.rb

RSpec.configure do |config|
  config.before(:suite) do
    # Reset Faker unique generators before the test suite
    Faker::UniqueGenerator.clear
  end

  config.before do
    # Optionally reset between tests if needed
    # Faker::UniqueGenerator.clear
  end
end
