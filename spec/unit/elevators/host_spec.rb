# frozen_string_literal: true

require 'spec_helper'
require 'rack'
require 'apartment/elevators/host'

RSpec.describe(Apartment::Elevators::Host) do
  let(:inner_app) { ->(_env) { [200, {}, ['ok']] } }

  def request_for(host)
    Rack::Request.new(Rack::MockRequest.env_for("http://#{host}/"))
  end

  describe '#parse_tenant_name' do
    it 'returns the full hostname' do
      elevator = described_class.new(inner_app)
      expect(elevator.parse_tenant_name(request_for('acme.example.com'))).to(eq('acme.example.com'))
    end

    it 'strips ignored first subdomains' do
      elevator = described_class.new(inner_app, ignored_first_subdomains: %w[www])
      expect(elevator.parse_tenant_name(request_for('www.example.com'))).to(eq('example.com'))
    end

    it 'does not strip non-ignored subdomains' do
      elevator = described_class.new(inner_app, ignored_first_subdomains: %w[www])
      expect(elevator.parse_tenant_name(request_for('acme.example.com'))).to(eq('acme.example.com'))
    end

    it 'returns nil for blank host' do
      elevator = described_class.new(inner_app)
      request = Rack::Request.new(Rack::MockRequest.env_for('/'))
      allow(request).to(receive(:host).and_return(''))
      expect(elevator.parse_tenant_name(request)).to(be_nil)
    end

    it 'coerces ignored_first_subdomains to strings' do
      elevator = described_class.new(inner_app, ignored_first_subdomains: [:www])
      expect(elevator.parse_tenant_name(request_for('www.example.com'))).to(eq('example.com'))
    end

    it 'freezes ignored_first_subdomains' do
      elevator = described_class.new(inner_app, ignored_first_subdomains: %w[www])
      expect(elevator.instance_variable_get(:@ignored_first_subdomains)).to(be_frozen)
    end
  end
end
