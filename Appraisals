# frozen_string_literal: true

appraise 'rails-6-1' do
  gem 'rails', '~> 6.1.0'
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
  platforms :ruby do
    gem 'sqlite3', '~> 1.4'
  end
  platforms :jruby do
    gem 'activerecord-jdbc-adapter', '~> 61.0'
    gem 'activerecord-jdbcpostgresql-adapter', '~> 61.0'
    gem 'activerecord-jdbcmysql-adapter', '~> 61.0'
  end
end

appraise 'rails-7-1' do
  gem 'rails', '~> 7.1.3'
  platforms :ruby do
    gem 'sqlite3', '~> 1.6'
  end
  platforms :jruby do
    gem 'activerecord-jdbc-adapter', '~> 61.0'
    gem 'activerecord-jdbcpostgresql-adapter', '~> 61.0'
    gem 'activerecord-jdbcmysql-adapter', '~> 61.0'
  end
end

appraise 'rails-master' do
  gem 'rails', git: 'https://github.com/rails/rails.git'
  platforms :ruby do
    gem 'sqlite3', '~> 1.4'
  end
  platforms :jruby do
    gem 'activerecord-jdbc-adapter', '~> 61.0'
    gem 'activerecord-jdbcpostgresql-adapter', '~> 61.0'
    gem 'activerecord-jdbcmysql-adapter', '~> 61.0'
  end
end
