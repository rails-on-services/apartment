# frozen_string_literal: true

require 'spec_helper'
require 'rack'
require 'apartment/elevators/domain'

RSpec.describe(Apartment::Elevators::Domain) do
  let(:inner_app) { ->(env) { [200, {}, ['ok']] } }

  def request_for(host)
    Rack::Request.new(Rack::MockRequest.env_for("http://#{host}/"))
  end

  describe '#parse_tenant_name' do
    it 'extracts domain name from simple host' do
      elevator = described_class.new(inner_app)
      expect(elevator.parse_tenant_name(request_for('example.com'))).to(eq('example'))
    end

    it 'strips www prefix' do
      elevator = described_class.new(inner_app)
      expect(elevator.parse_tenant_name(request_for('www.example.com'))).to(eq('example'))
    end

    it 'extracts first non-www segment with subdomains' do
      elevator = described_class.new(inner_app)
      expect(elevator.parse_tenant_name(request_for('a.example.bc.ca'))).to(eq('a'))
    end

    it 'strips www even with complex TLD' do
      elevator = described_class.new(inner_app)
      expect(elevator.parse_tenant_name(request_for('www.example.bc.ca'))).to(eq('example'))
    end

    it 'returns nil for blank host' do
      elevator = described_class.new(inner_app)
      request = Rack::Request.new(Rack::MockRequest.env_for('/'))
      allow(request).to(receive(:host).and_return(''))
      expect(elevator.parse_tenant_name(request)).to(be_nil)
    end
  end
end
