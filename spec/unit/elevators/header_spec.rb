# frozen_string_literal: true

require 'spec_helper'
require 'rack'
require 'apartment/elevators/header'

RSpec.describe(Apartment::Elevators::Header) do
  let(:inner_app) { ->(_env) { [200, {}, ['ok']] } }

  def env_with_header(header_name, value)
    rack_key = "HTTP_#{header_name.upcase.tr('-', '_')}"
    Rack::MockRequest.env_for('http://example.com/', rack_key => value)
  end

  describe '#parse_tenant_name' do
    it 'extracts tenant from the default X-Tenant-Id header' do
      elevator = described_class.new(inner_app)
      request = Rack::Request.new(env_with_header('X-Tenant-Id', 'acme'))
      expect(elevator.parse_tenant_name(request)).to(eq('acme'))
    end

    it 'extracts tenant from a custom header' do
      elevator = described_class.new(inner_app, header: 'X-CampusESP-Tenant')
      request = Rack::Request.new(env_with_header('X-CampusESP-Tenant', 'widgets'))
      expect(elevator.parse_tenant_name(request)).to(eq('widgets'))
    end

    it 'returns nil when header is missing' do
      elevator = described_class.new(inner_app)
      request = Rack::Request.new(Rack::MockRequest.env_for('http://example.com/'))
      expect(elevator.parse_tenant_name(request)).to(be_nil)
    end

    it 'handles header names with mixed case' do
      elevator = described_class.new(inner_app, header: 'x-tenant-id')
      request = Rack::Request.new(env_with_header('X-Tenant-Id', 'acme'))
      expect(elevator.parse_tenant_name(request)).to(eq('acme'))
    end

    it 'accepts trusted: without affecting behavior' do
      elevator = described_class.new(inner_app, trusted: true)
      request = Rack::Request.new(env_with_header('X-Tenant-Id', 'acme'))
      expect(elevator.parse_tenant_name(request)).to(eq('acme'))
    end
  end

  describe '#call' do
    it 'switches tenant when header is present' do
      elevator = described_class.new(inner_app)
      expect(Apartment::Tenant).to(receive(:switch).with('acme').and_yield)

      elevator.call(env_with_header('X-Tenant-Id', 'acme'))
    end

    it 'does not switch when header is absent' do
      elevator = described_class.new(inner_app)
      expect(Apartment::Tenant).not_to(receive(:switch))

      elevator.call(Rack::MockRequest.env_for('http://example.com/'))
    end
  end

  describe '#raw_header' do
    it 'returns the original header name' do
      elevator = described_class.new(inner_app, header: 'X-CampusESP-Tenant')
      expect(elevator.raw_header).to(eq('X-CampusESP-Tenant'))
    end

    it 'returns the default header name' do
      elevator = described_class.new(inner_app)
      expect(elevator.raw_header).to(eq('X-Tenant-Id'))
    end

    it 'is frozen' do
      elevator = described_class.new(inner_app)
      expect(elevator.raw_header).to(be_frozen)
    end
  end
end
