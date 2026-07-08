# frozen_string_literal: true

require 'spec_helper'
require 'rake'
require 'apartment/cli'

# Unit coverage for the apartment: rake wrappers in lib/apartment/tasks/v4.rake.
# The tasks are thin delegations to the Thor CLI; the confirmation policy lives
# in Apartment::CLI::Tenants (see spec/unit/cli/tenants_spec.rb). These specs
# load the task file into a throwaway Rake application and drive the *real* CLI
# (stubbing only Apartment::Tenant.drop, the boundary below it), so the
# rake -> CLI -> force?/TTY integration is exercised end to end rather than
# stubbed away.
RSpec.describe('apartment rake tasks') do
  around do |example|
    original_app = Rake.application
    Rake.application = Rake::Application.new
    # v4.rake declares `=> :environment`; stub it so the task can run headless.
    Rake::Task.define_task(:environment)
    load(File.expand_path('../../../lib/apartment/tasks/v4.rake', __dir__))
    example.run
  ensure
    Rake.application = original_app
  end

  before { allow(Apartment::Tenant).to(receive(:drop)) }

  # Issue #457: the wrapper hardcoded force: true, so the rake path was the only
  # drop entry point that never confirmed an irreversible operation. It now
  # delegates plainly to the CLI, whose policy requires an interactive TTY or an
  # explicit APARTMENT_FORCE=1 and otherwise aborts loudly.
  describe 'apartment:drop' do
    context 'when non-interactive (no TTY) without APARTMENT_FORCE' do
      around do |example|
        original = ENV.fetch('APARTMENT_FORCE', nil)
        ENV.delete('APARTMENT_FORCE')
        example.run
      ensure
        ENV['APARTMENT_FORCE'] = original
      end

      before { allow($stdin).to(receive(:tty?).and_return(false)) }

      # The wrapper reformats the CLI's Thor::Error as a clean abort (one-line
      # message, non-zero exit) rather than a raw `rake aborted!` backtrace.
      it 'aborts loudly with a clean message and never drops' do
        expect { Rake::Task['apartment:drop'].invoke('acme') }
          .to(raise_error(SystemExit).and(output(/APARTMENT_FORCE=1/).to_stderr))
        expect(Apartment::Tenant).not_to(have_received(:drop))
      end
    end

    context 'when non-interactive with APARTMENT_FORCE=1' do
      around do |example|
        original = ENV.fetch('APARTMENT_FORCE', nil)
        ENV['APARTMENT_FORCE'] = '1'
        example.run
      ensure
        ENV['APARTMENT_FORCE'] = original
      end

      before { allow($stdin).to(receive(:tty?).and_return(false)) }

      it 'drops without prompting (the real CLI honors APARTMENT_FORCE)' do
        Rake::Task['apartment:drop'].invoke('acme')

        expect(Apartment::Tenant).to(have_received(:drop).with('acme'))
      end
    end
  end
end
