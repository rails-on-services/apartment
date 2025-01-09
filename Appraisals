# frozen_string_literal: true

db_engine = ENV.fetch('DATABASE_ENGINE', 'all')

if %w[all postgresql].include?(db_engine)
  appraise 'rails-7-1-postgresql' do
    gem 'rails', '~> 7.1.0'
    gem 'pg', '~> 1.5'
  end
end

if %w[all mysql].include?(db_engine)
  appraise 'rails-7-1-mysql' do
    gem 'rails', '~> 7.1.0'
    gem 'mysql2', '~> 0.5'
    gem 'trilogy', '< 3.0'
  end
end

if %w[all sqlite].include?(db_engine)
  appraise 'rails-7-1-sqlite3' do
    gem 'rails', '~> 7.1.0'
    gem 'sqlite3', '~> 2.1'
  end
end

if %w[all postgresql].include?(db_engine)
  appraise 'rails-7-2-postgresql' do
    gem 'rails', '~> 7.2.0'
    gem 'pg', '~> 1.5'
  end
end

if %w[all mysql].include?(db_engine)
  appraise 'rails-7-2-mysql' do
    gem 'rails', '~> 7.2.0'
    gem 'mysql2', '~> 0.5'
    gem 'trilogy', '< 3.0'
  end
end

if %w[all sqlite].include?(db_engine)
  appraise 'rails-7-2-sqlite3' do
    gem 'rails', '~> 7.2.0'
    gem 'sqlite3', '~> 2.1'
  end
end

if %w[all postgresql].include?(db_engine)
  appraise 'rails-8-0-postgresql' do
    gem 'rails', '~> 8.0.0'
    gem 'pg', '~> 1.5'
  end
end

if %w[all mysql].include?(db_engine)
  appraise 'rails-8-0-mysql' do
    gem 'rails', '~> 8.0.0'
    gem 'mysql2', '~> 0.5'
    gem 'trilogy', '< 3.0'
  end
end

if %w[all sqlite].include?(db_engine)
  appraise 'rails-8-0-sqlite3' do
    gem 'rails', '~> 8.0.0'
    gem 'sqlite3', '~> 2.1'
  end
end
