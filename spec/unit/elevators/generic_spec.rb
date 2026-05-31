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

    it 'raises TenantNotFound with the tenant name intact, not a nested message' do
      elevator = described_class.new(app, ->(_req) { 'ghost' })
      expect { elevator.call(env) }.to(raise_error(Apartment::TenantNotFound) do |error|
        expect(error.tenant).to(eq('ghost'))
        expect(error.message).to(eq("Tenant 'ghost' not found"))
      end)
    end

    it 'passes the resolved tenant, not the host, when resolution raises TenantNotFound' do
      received = nil
      Apartment.configure do |c|
        c.tenant_strategy = :schema
        c.default_tenant = 'public'
        c.tenants_provider = -> { %w[acme] }
        c.tenant_not_found_handler = lambda { |tenant, _request|
          received = tenant
          [404, {}, []]
        }
      end
      processor = ->(_req) { raise(Apartment::TenantNotFound, 'resolved-name') }
      described_class.new(app, processor).call(env)
      expect(received).to(eq('resolved-name'))
    end
  end

  # The validator can hold a stale positive after another process drops a
  # tenant; the switch then proceeds and the app's first query blows up. The
  # fail-safe catches an adapter-classified "container gone" error, evicts the
  # name from this process, and routes through the not-found path — turning a
  # lingering-drop 500 into a 404. See issue #414.
  describe 'missing-tenant fail-safe' do
    let(:app) { ->(_env) { [200, {}, ['ok']] } }
    let(:env) { Rack::MockRequest.env_for('http://acme.example.com/') }
    # Stand-in for an adapter-specific "container gone" error class.
    let(:db_error_class) { Class.new(StandardError) }
    let(:validator) { instance_double(Apartment::TenantValidator, call: true, evict: nil) }

    before do
      Apartment.configure do |c|
        c.tenant_strategy = :schema
        c.default_tenant = 'public'
        c.tenants_provider = -> { %w[acme] }
      end
      allow(Apartment).to(receive(:tenant_validator).and_return(validator))
    end

    def stub_adapter(gone:)
      adapter = instance_double(Apartment::Adapters::AbstractAdapter,
                                failsafe_error_classes: [db_error_class])
      allow(adapter).to(receive(:tenant_container_gone?).and_return(gone))
      allow(Apartment).to(receive(:adapter).and_return(adapter))
      adapter
    end

    it 'evicts and routes through the not-found path on a confirmed missing container' do
      stub_adapter(gone: true)
      allow(Apartment::Tenant).to(receive(:switch).with('acme').and_raise(db_error_class, 'schema gone'))
      elevator = described_class.new(app, ->(_req) { 'acme' })

      expect { elevator.call(env) }.to(raise_error(Apartment::TenantNotFound, /acme/))
      expect(validator).to(have_received(:evict).with('acme'))
    end

    it 'returns the tenant_not_found_handler response on a confirmed missing container' do
      Apartment.configure do |c|
        c.tenant_strategy = :schema
        c.default_tenant = 'public'
        c.tenants_provider = -> { %w[acme] }
        c.tenant_not_found_handler = ->(tenant, _request) { [404, {}, ["gone: #{tenant}"]] }
      end
      stub_adapter(gone: true)
      allow(Apartment::Tenant).to(receive(:switch).with('acme').and_raise(db_error_class, 'schema gone'))
      elevator = described_class.new(app, ->(_req) { 'acme' })

      expect(elevator.call(env)).to(eq([404, {}, ['gone: acme']]))
    end

    it 're-raises the original error when the container still exists (not a drop)' do
      stub_adapter(gone: false)
      allow(Apartment::Tenant).to(receive(:switch).with('acme').and_raise(db_error_class, 'real bug'))
      elevator = described_class.new(app, ->(_req) { 'acme' })

      expect { elevator.call(env) }.to(raise_error(db_error_class, 'real bug'))
      expect(validator).not_to(have_received(:evict))
    end

    it 'does not classify errors outside the adapter failsafe set' do
      adapter = stub_adapter(gone: true)
      allow(Apartment::Tenant).to(receive(:switch).with('acme').and_raise(RuntimeError, 'unrelated'))
      elevator = described_class.new(app, ->(_req) { 'acme' })

      expect { elevator.call(env) }.to(raise_error(RuntimeError, 'unrelated'))
      expect(adapter).not_to(have_received(:tenant_container_gone?))
    end

    it 'leaves the happy path unwrapped when the adapter declares no failsafe errors' do
      adapter = instance_double(Apartment::Adapters::AbstractAdapter, failsafe_error_classes: [])
      allow(Apartment).to(receive(:adapter).and_return(adapter))
      allow(Apartment::Tenant).to(receive(:switch).with('acme').and_yield)
      elevator = described_class.new(app, ->(_req) { 'acme' })

      expect(elevator.call(env)).to(eq([200, {}, ['ok']]))
    end
  end
end
