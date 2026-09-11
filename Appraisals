# frozen_string_literal: true

# Apartment v4 support matrix: Rails 8.1+ × PostgreSQL/MySQL/SQLite3
# No JDBC (JRuby dropped in v4). No Rails < 8.1 (gemspec requires >= 8.1):
# 7.2 reached end-of-life 2026-08-09 and 8.0 stopped receiving bug fixes
# 2026-05-07, per https://rubyonrails.org/maintenance.
#
# Usage:
#   bundle exec appraisal install          # install all appraisals
#   bundle exec appraisal rspec spec/unit/ # run against all Rails versions
#   bundle exec appraisal rails-8.1-postgresql rspec spec/unit/ # single appraisal

# --- Rails 8.1 ---

appraise 'rails-8.1-postgresql' do
  gem 'rails', '~> 8.1.0'
  gem 'pg', '~> 1.6'
end

appraise 'rails-8.1-mysql2' do
  gem 'rails', '~> 8.1.0'
  gem 'mysql2', '~> 0.5'
end

appraise 'rails-8.1-trilogy' do
  gem 'rails', '~> 8.1.0'
  gem 'trilogy', '>= 2.9'
end

appraise 'rails-8.1-sqlite3' do
  gem 'rails', '~> 8.1.0'
  gem 'sqlite3', '~> 2.8'
end

# --- Rails main (catch regressions early) ---

appraise 'rails-main-postgresql' do
  gem 'rails', github: 'rails/rails', branch: 'main'
  gem 'pg', '~> 1.6'
end

appraise 'rails-main-sqlite3' do
  gem 'rails', github: 'rails/rails', branch: 'main'
  gem 'sqlite3', '~> 2.8'
end
