# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../lib/apartment/cli'

RSpec.describe(Apartment::CLI::Tenants) do
  before do
    Apartment.configure do |c|
      c.tenant_strategy = :schema
      c.tenants_provider = -> { %w[acme beta] }
      c.default_tenant = 'public'
    end
  end

  def run_command(*args)
    output = StringIO.new
    $stdout = output
    described_class.start(args)
    output.string
  ensure
    $stdout = STDOUT
  end

  describe 'create' do
    before do
      allow(Apartment::Tenant).to(receive(:create))
    end

    it 'creates a single tenant when given an argument' do
      run_command('create', 'acme')
      expect(Apartment::Tenant).to(have_received(:create).with('acme'))
    end

    it 'creates all tenants when no argument given' do
      run_command('create')
      expect(Apartment::Tenant).to(have_received(:create).with('acme'))
      expect(Apartment::Tenant).to(have_received(:create).with('beta'))
    end

    it 'skips tenants that already exist' do
      allow(Apartment::Tenant).to(receive(:create).with('acme')
        .and_raise(Apartment::TenantExists.new('acme')))
      output = run_command('create')
      expect(output).to(include('already exists'))
    end

    it 'collects errors and reports failures' do
      allow(Apartment::Tenant).to(receive(:create).with('acme')
        .and_raise(StandardError, 'connection refused'))
      allow(Apartment::Tenant).to(receive(:create).with('beta'))
      expect { run_command('create') }.to(raise_error(SystemExit))
    end

    it 'suppresses per-tenant output with --quiet' do
      output = run_command('create', '--quiet')
      expect(output).not_to(include('Creating'))
    end
  end

  describe 'drop' do
    before do
      allow(Apartment::Tenant).to(receive(:drop))
    end

    it 'drops the specified tenant with --force' do
      run_command('drop', 'acme', '--force')
      expect(Apartment::Tenant).to(have_received(:drop).with('acme'))
    end

    it 'prompts for confirmation without --force' do
      instance = described_class.new
      allow(instance).to(receive(:yes?).and_return(false))
      allow(instance).to(receive(:say))
      instance.drop('acme')
      expect(Apartment::Tenant).not_to(have_received(:drop))
    end

    it 'proceeds when confirmation is accepted' do
      instance = described_class.new
      allow(instance).to(receive(:yes?).and_return(true))
      allow(instance).to(receive(:say))
      instance.drop('acme')
      expect(Apartment::Tenant).to(have_received(:drop).with('acme'))
    end
  end

  describe 'list' do
    it 'prints all tenant names' do
      output = run_command('list')
      expect(output).to(include('acme'))
      expect(output).to(include('beta'))
    end
  end

  describe 'current' do
    it 'prints the current tenant' do
      Apartment::Current.tenant = 'acme'
      output = run_command('current')
      expect(output.strip).to(eq('acme'))
    end

    it 'prints default_tenant when no current tenant' do
      output = run_command('current')
      expect(output.strip).to(eq('public'))
    end

    it 'prints none when no tenant context' do
      # Use :database_name because :schema auto-defaults default_tenant to 'public'
      Apartment.configure do |c|
        c.tenant_strategy = :database_name
        c.tenants_provider = -> { [] }
      end
      output = run_command('current')
      expect(output.strip).to(eq('none'))
    end
  end

  describe 'APARTMENT_FORCE env var' do
    before do
      allow(Apartment::Tenant).to(receive(:drop))
    end

    it 'skips confirmation when APARTMENT_FORCE=1' do
      original = ENV.fetch('APARTMENT_FORCE', nil)
      ENV['APARTMENT_FORCE'] = '1'
      run_command('drop', 'acme')
      expect(Apartment::Tenant).to(have_received(:drop).with('acme'))
    ensure
      ENV['APARTMENT_FORCE'] = original
    end
  end

  describe 'APARTMENT_QUIET env var' do
    before do
      allow(Apartment::Tenant).to(receive(:create))
    end

    it 'suppresses output when APARTMENT_QUIET=1' do
      original = ENV.fetch('APARTMENT_QUIET', nil)
      ENV['APARTMENT_QUIET'] = '1'
      output = run_command('create')
      expect(output).not_to(include('Creating'))
    ensure
      ENV['APARTMENT_QUIET'] = original
    end
  end
end
