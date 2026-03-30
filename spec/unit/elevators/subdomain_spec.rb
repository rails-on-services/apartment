# frozen_string_literal: true

require 'spec_helper'
require 'rack'
require 'apartment/elevators/subdomain'

RSpec.describe(Apartment::Elevators::Subdomain) do
  let(:inner_app) { ->(_env) { [200, {}, ['ok']] } }

  def env_for(host)
    Rack::MockRequest.env_for("http://#{host}/")
  end

  def request_for(host)
    Rack::Request.new(env_for(host))
  end

  describe '#parse_tenant_name' do
    it 'extracts subdomain from host' do
      elevator = described_class.new(inner_app)
      expect(elevator.parse_tenant_name(request_for('acme.example.com'))).to(eq('acme'))
    end

    it 'returns nil for excluded subdomains' do
      elevator = described_class.new(inner_app, excluded_subdomains: %w[www api])
      expect(elevator.parse_tenant_name(request_for('www.example.com'))).to(be_nil)
    end

    it 'returns nil for bare domain (no subdomain)' do
      elevator = described_class.new(inner_app)
      expect(elevator.parse_tenant_name(request_for('example.com'))).to(be_nil)
    end

    it 'returns nil for IP addresses' do
      elevator = described_class.new(inner_app)
      expect(elevator.parse_tenant_name(request_for('127.0.0.1'))).to(be_nil)
    end

    it 'handles international TLDs correctly' do
      elevator = described_class.new(inner_app)
      expect(elevator.parse_tenant_name(request_for('acme.example.co.uk'))).to(eq('acme'))
    end

    it 'coerces excluded_subdomains to strings' do
      elevator = described_class.new(inner_app, excluded_subdomains: [:www])
      expect(elevator.parse_tenant_name(request_for('www.example.com'))).to(be_nil)
    end

    it 'freezes excluded_subdomains' do
      elevator = described_class.new(inner_app, excluded_subdomains: %w[www])
      expect(elevator.instance_variable_get(:@excluded_subdomains)).to(be_frozen)
    end
  end
end
