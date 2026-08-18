# frozen_string_literal: true

require 'spec_helper'

RSpec.describe(Apartment::Privileges) do
  describe '.standard' do
    let(:connection) { double('Connection') }
    let(:adapter) { double('Adapter') }

    def context(phase = :before_schema_load)
      described_class::Context.new(
        tenant: 'acme', container_name: 'acme', connection: connection,
        db_role: 'db_manager', phase: phase
      )
    end

    before { allow(Apartment).to(receive(:adapter).and_return(adapter)) }

    it 'returns a callable, so it can be assigned straight to the config key' do
      expect(described_class.standard(grant_to: 'app_user')).to(respond_to(:call))
    end

    it 'executes the statements the adapter supplies for that phase', :aggregate_failures do
      allow(adapter).to(receive(:standard_privilege_statements)
        .with(anything, grant_to: ['app_user'], include_functions: true)
        .and_return(['GRANT A', 'GRANT B']))
      allow(connection).to(receive(:execute))

      described_class.standard(grant_to: 'app_user').call(context)

      expect(connection).to(have_received(:execute).with('GRANT A').ordered)
      expect(connection).to(have_received(:execute).with('GRANT B').ordered)
    end

    it 'passes include_functions through' do
      expect(adapter).to(receive(:standard_privilege_statements)
        .with(anything, grant_to: ['app_user'], include_functions: false)
        .and_return([]))

      described_class.standard(grant_to: 'app_user', include_functions: false).call(context)
    end

    # The phase mapping is the adapter's; the policy must not second-guess it.
    it 'executes nothing when the adapter needs no statements in this phase' do
      allow(adapter).to(receive(:standard_privilege_statements).and_return([]))
      expect(connection).not_to(receive(:execute))

      described_class.standard(grant_to: 'app_user').call(context(:after_schema_load))
    end

    it 'accepts an Array of roles and forwards it as given' do
      expect(adapter).to(receive(:standard_privilege_statements)
        .with(anything, grant_to: %w[app_web app_worker], include_functions: true)
        .and_return([]))

      described_class.standard(grant_to: %w[app_web app_worker]).call(context)
    end

    it 'rejects an empty grant_to at build time, not at create time' do
      expect { described_class.standard(grant_to: []) }
        .to(raise_error(Apartment::ConfigurationError, /grant_to/))
    end

    it 'rejects a non-String grant_to' do
      expect { described_class.standard(grant_to: [:app_user]) }
        .to(raise_error(Apartment::ConfigurationError, /grant_to/))
    end
  end
end
