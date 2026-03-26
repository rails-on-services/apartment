# frozen_string_literal: true

$LOAD_PATH << File.expand_path('lib', __dir__)
require 'apartment/version'

Gem::Specification.new do |s|
  s.name = 'ros-apartment'
  s.version = Apartment::VERSION

  s.authors       = ['Ryan Brunner', 'Brad Robertson', 'Rui Baltazar', 'Mauricio Novelo']
  s.summary       = 'Database multitenancy for Rack/Rails applications via ActiveRecord'
  s.description   = 'Apartment provides multitenancy for Rails and Rack applications ' \
                    'through schema-based or database-based isolation strategies.'
  s.email         = ['ryan@influitive.com', 'brad@influitive.com', 'rui.p.baltazar@gmail.com', 'mauricio@campusesp.com']

  s.files = %w[ros-apartment.gemspec README.md] + `git ls-files -- lib`.split("\n")
  s.require_paths = ['lib']

  s.homepage = 'https://github.com/rails-on-services/apartment'
  s.licenses = ['MIT']
  s.metadata = {
    'github_repo' => 'ssh://github.com/rails-on-services/apartment',
    'rubygems_mfa_required' => 'true',
  }

  s.required_ruby_version = '>= 3.3'

  s.add_dependency('activerecord',    '>= 7.2.0', '< 8.2')
  s.add_dependency('activesupport',   '>= 7.2.0', '< 8.2')
  s.add_dependency('concurrent-ruby', '>= 1.3.0')
  s.add_dependency('parallel',        '>= 1.26.0')
  s.add_dependency('public_suffix',   '>= 2.0.5', '< 7')
  s.add_dependency('rack',            '>= 3.0.9', '< 4.0')
  s.add_dependency('thor',            '>= 1.3.0')
  s.add_dependency('zeitwerk',        '>= 2.7.1')
end
