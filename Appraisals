# frozen_string_literal: true

# nio4r v2.7.2 is broken on jruby
# that's why we pin it to a specific version for now
# https://github.com/socketry/nio4r/issues/315

appraise 'rails-6-1' do
  gem 'rails', '~> 6.1.0'
  platforms :ruby do
    gem 'sqlite3', '~> 1.4'
  end
  platforms :jruby do
    gem 'nio4r', '2.7.1'

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
    gem 'nio4r', '2.7.1'

    gem 'activerecord-jdbc-adapter', '~> 70.0'
    gem 'activerecord-jdbcpostgresql-adapter', '~> 70.0'
    gem 'activerecord-jdbcmysql-adapter', '~> 70.0'
  end
end

appraise 'rails-7-1' do
  gem 'rails', '~> 7.1.0'
  platforms :ruby do
    gem 'sqlite3', '~> 1.6'
  end
  platforms :jruby do
    gem 'nio4r', '2.7.1'

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
    gem 'nio4r', '2.7.1'

    # a JDBC adapter for Rails 7.1 does not exist yet
    gem 'activerecord-jdbc-adapter', '~> 61.0'
    gem 'activerecord-jdbcpostgresql-adapter', '~> 61.0'
    gem 'activerecord-jdbcmysql-adapter', '~> 61.0'
  end
end
