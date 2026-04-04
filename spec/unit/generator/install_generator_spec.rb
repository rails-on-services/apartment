# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'tmpdir'

begin
  require 'rails/generators'
  require 'rails/generators/testing/behavior'
  require 'rails/generators/testing/assertions'
  require_relative '../../../lib/generators/apartment/install/install_generator'
rescue LoadError
  # Rails generators not available (base Gemfile without Rails).
  # These specs only run under appraisal.
end

return unless defined?(Rails::Generators)

RSpec.describe(Apartment::InstallGenerator) do
  include FileUtils

  let(:destination) { Dir.mktmpdir }

  before do
    described_class.start([], destination_root: destination, quiet: true)
  end

  after do
    rm_rf(destination)
  end

  describe 'initializer' do
    let(:initializer_path) { File.join(destination, 'config', 'initializers', 'apartment.rb') }

    it 'creates the initializer file' do
      expect(File.exist?(initializer_path)).to(be(true))
    end

    it 'contains tenant_strategy' do
      content = File.read(initializer_path)
      expect(content).to(include('config.tenant_strategy'))
    end

    it 'contains tenants_provider' do
      content = File.read(initializer_path)
      expect(content).to(include('config.tenants_provider'))
    end

    it 'does not contain v3 references' do
      content = File.read(initializer_path)
      expect(content).not_to(include('tenant_names'))
      expect(content).not_to(include('use_schemas'))
      expect(content).not_to(include('use_sql'))
      expect(content).not_to(include('prepend_environment'))
      expect(content).not_to(include('pg_excluded_names'))
      expect(content).not_to(include('middleware.use'))
    end

    it 'does not require elevator files' do
      content = File.read(initializer_path)
      expect(content).not_to(include("require 'apartment/elevators"))
    end

    it 'includes RBAC options in comments' do
      content = File.read(initializer_path)
      expect(content).to(include('migration_role'))
      expect(content).to(include('app_role'))
    end

    it 'includes elevator options in comments' do
      content = File.read(initializer_path)
      expect(content).to(include('config.elevator'))
      expect(content).to(include('elevator_options'))
    end
  end

  describe 'binstub' do
    let(:binstub_path) { File.join(destination, 'bin', 'apartment') }

    it 'creates the binstub file' do
      expect(File.exist?(binstub_path)).to(be(true))
    end

    it 'is executable' do
      expect(File.executable?(binstub_path)).to(be(true))
    end

    it 'requires config/environment' do
      content = File.read(binstub_path)
      expect(content).to(include("require_relative '../config/environment'"))
    end

    it 'requires apartment/cli' do
      content = File.read(binstub_path)
      expect(content).to(include("require 'apartment/cli'"))
    end

    it 'starts CLI' do
      content = File.read(binstub_path)
      expect(content).to(include('Apartment::CLI.start'))
    end
  end
end
