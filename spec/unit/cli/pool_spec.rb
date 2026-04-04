# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../lib/apartment/cli'

RSpec.describe(Apartment::CLI::Pool) do
  def run_command(*args)
    output = StringIO.new
    $stdout = output
    described_class.start(args)
    output.string
  ensure
    $stdout = STDOUT
  end

  describe 'stats' do
    context 'when pool_manager is configured' do
      before do
        Apartment.configure do |c|
          c.tenant_strategy = :schema
          c.tenants_provider = -> { %w[acme beta] }
          c.default_tenant = 'public'
        end
      end

      it 'prints pool summary' do
        Apartment.pool_manager.fetch_or_create('acme') { double('pool') }
        output = run_command('stats')
        expect(output).to(include('pool'))
      end

      it 'prints per-tenant details with --verbose' do
        Apartment.pool_manager.fetch_or_create('acme') { double('pool') }
        output = run_command('stats', '--verbose')
        expect(output).to(include('acme'))
      end
    end

    context 'when pool_manager is nil' do
      before { Apartment.clear_config }

      it 'prints a not-configured message' do
        output = run_command('stats')
        expect(output).to(include('not configured'))
      end
    end
  end

  describe 'evict' do
    before do
      Apartment.configure do |c|
        c.tenant_strategy = :schema
        c.tenants_provider = -> { [] }
        c.default_tenant = 'public'
      end
    end

    it 'runs eviction cycle with --force' do
      allow(Apartment.pool_reaper).to(receive(:run_cycle).and_return(3))
      output = run_command('evict', '--force')
      expect(output).to(include('3'))
      expect(Apartment.pool_reaper).to(have_received(:run_cycle))
    end

    it 'prompts without --force' do
      instance = described_class.new
      allow(instance).to(receive(:yes?).and_return(false))
      allow(instance).to(receive(:say))
      allow(Apartment.pool_reaper).to(receive(:run_cycle))
      instance.evict
      expect(Apartment.pool_reaper).not_to(have_received(:run_cycle))
    end

    it 'reports when pool_reaper is nil' do
      Apartment.clear_config
      output = run_command('evict', '--force')
      expect(output).to(include('not configured'))
    end
  end
end
