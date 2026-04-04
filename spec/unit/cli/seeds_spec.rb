# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../lib/apartment/cli'

RSpec.describe(Apartment::CLI::Seeds) do
  before do
    Apartment.configure do |c|
      c.tenant_strategy = :schema
      c.tenants_provider = -> { %w[acme beta] }
      c.default_tenant = 'public'
    end
    allow(Apartment::Tenant).to(receive(:seed))
  end

  def run_command(*args)
    output = StringIO.new
    $stdout = output
    described_class.start(args)
    output.string
  ensure
    $stdout = STDOUT
  end

  describe 'seed' do
    it 'seeds a single tenant when given an argument' do
      run_command('seed', 'acme')
      expect(Apartment::Tenant).to(have_received(:seed).with('acme'))
    end

    it 'seeds all tenants when no argument given' do
      run_command('seed')
      expect(Apartment::Tenant).to(have_received(:seed).with('acme'))
      expect(Apartment::Tenant).to(have_received(:seed).with('beta'))
    end

    it 'collects errors and exits non-zero' do
      allow(Apartment::Tenant).to(receive(:seed).with('acme')
        .and_raise(StandardError, 'seed error'))
      expect { run_command('seed') }.to(raise_error(SystemExit))
    end

    it 'prints per-tenant output' do
      output = run_command('seed')
      expect(output).to(include('acme'))
      expect(output).to(include('beta'))
    end
  end
end
