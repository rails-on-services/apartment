# frozen_string_literal: true

require('tmpdir')
require('fileutils')

# Integration tests require real ActiveRecord + sqlite3.
# Run via: bundle exec appraisal rails-8.1-sqlite3 rspec spec/integration/v4/
V4_INTEGRATION_AVAILABLE = begin
  require('active_record')
  require('apartment/adapters/sqlite3_adapter')
  ActiveRecord::Base.respond_to?(:establish_connection)
rescue LoadError
  false
end
