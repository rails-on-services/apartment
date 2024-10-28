# frozen_string_literal: true

$LOAD_PATH << File.expand_path('lib', __dir__)
require 'apartment/version'

Gem::Specification.new do |s|
  s.name = 'ros-apartment'
  s.version = Apartment::VERSION

  s.authors       = ['Ryan Brunner', 'Brad Robertson', 'Rui Baltazar', 'Mauricio Novelo']
  s.summary       = 'A Ruby gem for managing database multitenancy. Apartment Gem drop in replacement'
  s.description   = 'Apartment allows Rack applications to deal with database multitenancy through ActiveRecord'
  s.email         = ['ryan@influitive.com', 'brad@influitive.com', 'rui.p.baltazar@gmail.com', 'mauricio@campusesp.com']
  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been
  # added into git.
  s.files = Dir.chdir(File.expand_path(__dir__)) do
    `git ls-files -z`.split("\x0").reject do |f|
      # NOTE: ignore all test related
      f.match(%r{^(test|spec|features|documentation|gemfiles|.github)/})
    end
  end
  s.executables   = s.files.grep(%r{^bin/}).map { |f| File.basename(f) }
  s.require_paths = ['lib']

  s.homepage = 'https://github.com/rails-on-services/apartment'
  s.licenses = ['MIT']
  s.metadata = {
    'github_repo' => 'ssh://github.com/rails-on-services/apartment',
    'rubygems_mfa_required' => 'true',
  }

  s.required_ruby_version = '>= 3.1', '<= 3.4'

  s.add_dependency('activerecord', '>= 6.1.0', '< 8.1')
  s.add_dependency('activesupport', '>= 6.1.0', '< 8.1')
  s.add_dependency('parallel', '< 2.0')
  s.add_dependency('public_suffix', '>= 2.0.5', '<= 6.0.1')
  s.add_dependency('rack', '>= 1.3.6', '< 4.0')
end
