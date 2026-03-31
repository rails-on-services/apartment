# frozen_string_literal: true

require 'spec_helper'
require_relative '../../lib/apartment/migrator'

RSpec.describe(Apartment::Migrator::Result) do
  subject(:result) do
    described_class.new(
      tenant: 'acme',
      status: :success,
      duration: 1.23,
      error: nil,
      versions_run: [20260401000000, 20260402000000]
    )
  end

  it 'is frozen (Data.define)' do
    expect(result).to(be_frozen)
  end

  it 'exposes all attributes' do
    expect(result.tenant).to(eq('acme'))
    expect(result.status).to(eq(:success))
    expect(result.duration).to(eq(1.23))
    expect(result.error).to(be_nil)
    expect(result.versions_run).to(eq([20260401000000, 20260402000000]))
  end
end

RSpec.describe(Apartment::Migrator::MigrationRun) do
  let(:success_result) do
    Apartment::Migrator::Result.new(
      tenant: 'acme', status: :success, duration: 1.0, error: nil, versions_run: [1]
    )
  end
  let(:failed_result) do
    Apartment::Migrator::Result.new(
      tenant: 'broken', status: :failed, duration: 0.5,
      error: StandardError.new('boom'), versions_run: []
    )
  end
  let(:skipped_result) do
    Apartment::Migrator::Result.new(
      tenant: 'current', status: :skipped, duration: 0.01, error: nil, versions_run: []
    )
  end

  subject(:run) do
    described_class.new(
      results: [success_result, failed_result, skipped_result],
      total_duration: 2.5,
      threads: 4
    )
  end

  describe '#succeeded' do
    it 'returns only success results' do
      expect(run.succeeded.map(&:tenant)).to(eq(['acme']))
    end
  end

  describe '#failed' do
    it 'returns only failed results' do
      expect(run.failed.map(&:tenant)).to(eq(['broken']))
    end
  end

  describe '#skipped' do
    it 'returns only skipped results' do
      expect(run.skipped.map(&:tenant)).to(eq(['current']))
    end
  end

  describe '#success?' do
    it 'returns false when there are failures' do
      expect(run.success?).to(be(false))
    end

    it 'returns true when no failures' do
      all_good = described_class.new(
        results: [success_result, skipped_result], total_duration: 1.0, threads: 2
      )
      expect(all_good.success?).to(be(true))
    end
  end

  describe '#summary' do
    it 'includes counts and timing' do
      summary = run.summary
      expect(summary).to(include('3 tenants'))
      expect(summary).to(include('2.5s'))
      expect(summary).to(include('1 succeeded'))
      expect(summary).to(include('1 failed'))
      expect(summary).to(include('1 skipped'))
      expect(summary).to(include('broken'))
    end
  end
end
