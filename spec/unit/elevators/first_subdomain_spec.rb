# frozen_string_literal: true

require 'spec_helper'
require 'rack'
require 'apartment/elevators/first_subdomain'

RSpec.describe(Apartment::Elevators::FirstSubdomain) do
  let(:inner_app) { ->(env) { [200, {}, ['ok']] } }

  def request_for(host)
    Rack::Request.new(Rack::MockRequest.env_for("http://#{host}/"))
  end

  describe '#parse_tenant_name' do
    it 'extracts the first subdomain segment' do
      elevator = described_class.new(inner_app)
      expect(elevator.parse_tenant_name(request_for('acme.staging.example.com'))).to(eq('acme'))
    end

    it 'works with a single subdomain' do
      elevator = described_class.new(inner_app)
      expect(elevator.parse_tenant_name(request_for('acme.example.com'))).to(eq('acme'))
    end

    it 'returns nil when no subdomain' do
      elevator = described_class.new(inner_app)
      expect(elevator.parse_tenant_name(request_for('example.com'))).to(be_nil)
    end

    it 'respects excluded_subdomains from Subdomain' do
      elevator = described_class.new(inner_app, excluded_subdomains: %w[www])
      expect(elevator.parse_tenant_name(request_for('www.example.com'))).to(be_nil)
    end
  end
end
