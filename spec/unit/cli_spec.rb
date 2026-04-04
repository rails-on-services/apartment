# frozen_string_literal: true

require 'spec_helper'
require_relative '../../lib/apartment/cli'

RSpec.describe(Apartment::CLI) do
  describe '.exit_on_failure?' do
    it 'returns true' do
      expect(described_class.exit_on_failure?).to(be(true))
    end
  end

  describe 'subcommand registration' do
    it 'registers tenants subcommand' do
      expect(help_output).to(include('tenants'))
    end

    it 'registers migrations subcommand' do
      expect(help_output).to(include('migrations'))
    end

    it 'registers seeds subcommand' do
      expect(help_output).to(include('seeds'))
    end

    it 'registers pool subcommand' do
      expect(help_output).to(include('pool'))
    end
  end

  private

  def help_output
    @help_output ||= capture_stdout { described_class.start(['help']) }
  end

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end
end
