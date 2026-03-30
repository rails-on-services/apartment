# frozen_string_literal: true

require 'spec_helper'
require 'rack'
require 'apartment/elevators/generic'

RSpec.describe(Apartment::Elevators::Generic) do
  let(:inner_app) { ->(env) { [200, { 'Content-Type' => 'text/plain' }, [env['apartment.tenant'] || 'default']] } }

  describe '#call' do
    it 'switches tenant when processor returns a tenant name' do
      elevator = described_class.new(inner_app, ->(_req) { 'acme' })

      expect(Apartment::Tenant).to(receive(:switch).with('acme').and_yield)

      elevator.call(Rack::MockRequest.env_for('http://example.com'))
    end

    it 'does not switch when processor returns nil' do
      elevator = described_class.new(inner_app, ->(_req) {})

      expect(Apartment::Tenant).not_to(receive(:switch))

      elevator.call(Rack::MockRequest.env_for('http://example.com'))
    end

    it 'calls the inner app' do
      elevator = described_class.new(inner_app, ->(_req) {})

      status, = elevator.call(Rack::MockRequest.env_for('http://example.com'))
      expect(status).to(eq(200))
    end

    it 'uses parse_tenant_name when no processor provided' do
      subclass = Class.new(described_class) do
        def parse_tenant_name(_request)
          'from_subclass'
        end
      end

      elevator = subclass.new(inner_app)
      expect(Apartment::Tenant).to(receive(:switch).with('from_subclass').and_yield)

      elevator.call(Rack::MockRequest.env_for('http://example.com'))
    end

    it 'absorbs keyword args without error' do
      expect { described_class.new(inner_app, nil, some_option: 'value') }.not_to(raise_error)
    end
  end

  describe '#parse_tenant_name' do
    it 'raises NotImplementedError by default' do
      elevator = described_class.new(inner_app)
      request = Rack::Request.new(Rack::MockRequest.env_for('http://example.com'))

      expect { elevator.parse_tenant_name(request) }
        .to(raise_error(NotImplementedError, /parse_tenant_name must be implemented/))
    end
  end
end
