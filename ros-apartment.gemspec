# frozen_string_literal: true

require_relative 'lib/apartment/version'

Gem::Specification.new do |s|
  s.name = 'ros-apartment'
  s.version = Apartment::VERSION

  s.authors       = ['Ryan Brunner', 'Brad Robertson', 'Rui Baltazar', 'Mauricio Novelo']
  s.summary       = 'A Ruby gem for managing database multi-tenancy. Apartment Gem drop in replacement'
  s.description   = 'Apartment allows Rack applications to deal with database multi-tenancy through ActiveRecord'
  s.email         = ['ryan@influitive.com', 'brad@influitive.com', 'rui.p.baltazar@gmail.com', 'mauricio@campusesp.com']
  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been
  # added into git.
  s.files = %w[ros-apartment.gemspec README.md] + `git ls-files -z | grep -E '^lib'`.split("\n")
  s.executables = s.files.grep(%r{^bin/}).map { |f| File.basename(f) }

  s.licenses = ['MIT']
  s.metadata = {
    'homepage_uri' => 'https://github.com/rails-on-services/apartment',
    'bug_tracker_uri' => 'https://github.com/rails-on-services/apartment/issues',
    'changelog_uri' => 'https://github.com/rails-on-services/apartment/releases',
    'source_code_uri' => 'https://github.com/rails-on-services/apartment',
    'rubygems_mfa_required' => 'true',
  }

  s.required_ruby_version = '>= 3.2'

  s.add_dependency('activerecord', '>= 7.1.0', '< 8.1')
  s.add_dependency('activesupport', '>= 7.1.0', '< 8.1')
  s.add_dependency('concurrent-ruby', '>= 1.3.0')
  s.add_dependency('parallel', '>= 1.26.0')
  s.add_dependency('public_suffix', '>= 6.0.1')
  s.add_dependency('rack', '>= 3.0.9', '< 4.0')
  s.add_dependency('zeitwerk', '>= 2.7.1')
end
