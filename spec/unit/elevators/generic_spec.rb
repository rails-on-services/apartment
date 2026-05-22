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

    it 'propagates exceptions from parse_tenant_name' do
      elevator = described_class.new(inner_app, ->(_req) { raise(Apartment::TenantNotFound, 'bad') })

      expect { elevator.call(Rack::MockRequest.env_for('http://example.com')) }
        .to(raise_error(Apartment::TenantNotFound))
    end

    it 'propagates exceptions from Tenant.switch' do
      elevator = described_class.new(inner_app, ->(_req) { 'acme' })

      allow(Apartment::Tenant).to(receive(:switch).and_raise(Apartment::TenantNotFound, 'acme'))

      expect { elevator.call(Rack::MockRequest.env_for('http://example.com')) }
        .to(raise_error(Apartment::TenantNotFound))
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

  describe 'tenant validation' do
    let(:app) { ->(_env) { [200, {}, ['ok']] } }
    let(:env) { Rack::MockRequest.env_for('http://acme.example.com/') }

    before do
      Apartment.configure do |c|
        c.tenant_strategy = :schema
        c.default_tenant = 'public'
        c.tenants_provider = -> { %w[acme] }
      end
    end

    it 'switches when the resolved tenant is valid' do
      switched = nil
      allow(Apartment::Tenant).to(receive(:switch)) do |name, &blk|
        switched = name
        blk.call
      end
      elevator = described_class.new(app, ->(_req) { 'acme' })
      elevator.call(env)
      expect(switched).to(eq('acme'))
    end

    it 'raises TenantNotFound when the resolved tenant is invalid and no handler is set' do
      elevator = described_class.new(app, ->(_req) { 'ghost' })
      expect { elevator.call(env) }.to(raise_error(Apartment::TenantNotFound, /ghost/))
    end

    it 'calls tenant_not_found_handler when configured, returning its Rack response' do
      Apartment.configure do |c|
        c.tenant_strategy = :schema
        c.default_tenant = 'public'
        c.tenants_provider = -> { %w[acme] }
        c.tenant_not_found_handler = ->(tenant, _request) { [404, {}, ["no #{tenant}"]] }
      end
      elevator = described_class.new(app, ->(_req) { 'ghost' })
      expect(elevator.call(env)).to(eq([404, {}, ['no ghost']]))
    end

    it 'does not validate when the processor returns nil (default tenant)' do
      elevator = described_class.new(app, ->(_req) {})
      expect(elevator.call(env)).to(eq([200, {}, ['ok']]))
    end

    it 'treats the default tenant as always valid' do
      switched = nil
      allow(Apartment::Tenant).to(receive(:switch)) do |name, &blk|
        switched = name
        blk.call
      end
      elevator = described_class.new(app, ->(_req) { 'public' })
      elevator.call(env)
      expect(switched).to(eq('public'))
    end

    it 'routes a TenantNotFound raised during resolution through the handler' do
      Apartment.configure do |c|
        c.tenant_strategy = :schema
        c.default_tenant = 'public'
        c.tenants_provider = -> { %w[acme] }
        c.tenant_not_found_handler = ->(_tenant, _request) { [404, {}, ['routed']] }
      end
      processor = ->(_req) { raise(Apartment::TenantNotFound, 'unmapped host') }
      elevator = described_class.new(app, processor)
      expect(elevator.call(env)).to(eq([404, {}, ['routed']]))
    end
  end
end
