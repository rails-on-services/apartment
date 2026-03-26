# frozen_string_literal: true

# Apartment v4 support matrix: Rails 7.2+ × PostgreSQL/MySQL/SQLite3
# No JDBC (JRuby dropped in v4). No Rails < 7.2 (gemspec requires >= 7.2).
#
# Usage:
#   bundle exec appraisal install          # install all appraisals
#   bundle exec appraisal rspec spec/unit/ # run against all Rails versions
#   bundle exec appraisal rails-7.2-postgresql rspec spec/unit/ # single appraisal

# --- Rails 7.2 ---

appraise 'rails-7.2-postgresql' do
  gem 'rails', '~> 7.2.0'
  gem 'pg', '~> 1.5'
end

appraise 'rails-7.2-mysql2' do
  gem 'rails', '~> 7.2.0'
  gem 'mysql2', '~> 0.5'
end

appraise 'rails-7.2-trilogy' do
  gem 'rails', '~> 7.2.0'
  gem 'trilogy', '>= 2.9'
end

appraise 'rails-7.2-sqlite3' do
  gem 'rails', '~> 7.2.0'
  gem 'sqlite3', '~> 2.1'
end

# --- Rails 8.0 ---

appraise 'rails-8.0-postgresql' do
  gem 'rails', '~> 8.0.0'
  gem 'pg', '~> 1.5'
end

appraise 'rails-8.0-mysql2' do
  gem 'rails', '~> 8.0.0'
  gem 'mysql2', '~> 0.5'
end

appraise 'rails-8.0-trilogy' do
  gem 'rails', '~> 8.0.0'
  gem 'trilogy', '>= 2.9'
end

appraise 'rails-8.0-sqlite3' do
  gem 'rails', '~> 8.0.0'
  gem 'sqlite3', '~> 2.1'
end

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
