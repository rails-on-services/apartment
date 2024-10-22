# frozen_string_literal: true

appraise 'rails-6-1' do
  gem 'rails', '~> 6.1.0'
  gem 'rspec-rails', '~> 6.1.0'

  platforms :ruby do
    gem 'sqlite3', '~> 1.4'
  end

  platforms :jruby do
    gem 'activerecord-jdbc-adapter', '~> 61.0'
    gem 'activerecord-jdbcpostgresql-adapter', '~> 61.0'
    gem 'activerecord-jdbcmysql-adapter', '~> 61.0'
  end
end

appraise 'rails-7-0' do
  gem 'rails', '~> 7.0.0'
  gem 'rspec-rails', '~> 7.0.0'

  platforms :ruby do
    gem 'sqlite3', '~> 1.4'
  end

  platforms :jruby do
    gem 'activerecord-jdbc-adapter', '~> 70.0'
    gem 'activerecord-jdbcpostgresql-adapter', '~> 70.0'
    gem 'activerecord-jdbcmysql-adapter', '~> 70.0'
  end
end

appraise 'rails-7-1' do
  gem 'rails', '~> 7.1.0'
  gem 'rspec-rails', '~> 7.1.0'

  platforms :ruby do
    gem 'sqlite3', '~> 1.6'
  end

  platforms :jruby do
    gem 'activerecord-jdbc-adapter', '~> 71.0'
    gem 'activerecord-jdbcpostgresql-adapter', '~> 71.0'
    gem 'activerecord-jdbcmysql-adapter', '~> 71.0'
  end
end

appraise 'rails-7-2' do
  gem 'rails', '~> 7.2.0'
  gem 'rspec-rails', '~> 7.2.0'

  platforms :ruby do
    gem 'sqlite3', '~> 1.6'
  end

  platforms :jruby do
    gem 'activerecord-jdbc-adapter', '~> 70.0'
    gem 'activerecord-jdbcpostgresql-adapter', '~> 70.0'
    gem 'activerecord-jdbcmysql-adapter', '~> 70.0'
  end
end

# Install Rails from the main branch are failing
# appraise 'rails-master' do
#   gem 'rails', git: 'https://github.com/rails/rails.git'
#   platforms :ruby do
#     gem 'sqlite3', '~> 2.0'
#   end
#   platforms :jruby do
#     gem 'activerecord-jdbc-adapter', '~> 61.0'
#     gem 'activerecord-jdbcpostgresql-adapter', '~> 61.0'
#     gem 'activerecord-jdbcmysql-adapter', '~> 61.0'
#   end
# end
