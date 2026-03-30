# frozen_string_literal: true

require 'spec_helper'
require 'rack'
require 'apartment/elevators/host_hash'

RSpec.describe(Apartment::Elevators::HostHash) do
  let(:inner_app) { ->(_env) { [200, {}, ['ok']] } }
  let(:mapping) { { 'acme.com' => 'acme', 'widgets.io' => 'widgets' } }

  def request_for(host)
    Rack::Request.new(Rack::MockRequest.env_for("http://#{host}/"))
  end

  describe '#parse_tenant_name' do
    it 'returns the mapped tenant for a known host' do
      elevator = described_class.new(inner_app, hash: mapping)
      expect(elevator.parse_tenant_name(request_for('acme.com'))).to(eq('acme'))
    end

    it 'raises TenantNotFound for an unknown host' do
      elevator = described_class.new(inner_app, hash: mapping)
      expect { elevator.parse_tenant_name(request_for('unknown.com')) }
        .to(raise_error(Apartment::TenantNotFound, /unknown\.com/))
    end

    it 'sets the tenant attribute on TenantNotFound' do
      elevator = described_class.new(inner_app, hash: mapping)
      expect { elevator.parse_tenant_name(request_for('unknown.com')) }
        .to(raise_error { |e| expect(e.tenant).to(eq('unknown.com')) })
    end

    it 'freezes the hash' do
      elevator = described_class.new(inner_app, hash: mapping)
      expect(elevator.instance_variable_get(:@hash)).to(be_frozen)
    end

    it 'defaults to empty hash' do
      elevator = described_class.new(inner_app)
      expect { elevator.parse_tenant_name(request_for('anything.com')) }
        .to(raise_error(Apartment::TenantNotFound))
    end
  end

  describe '#call' do
    it 'raises TenantNotFound for unknown host through full call stack' do
      elevator = described_class.new(inner_app, hash: { 'known.com' => 'acme' })
      expect { elevator.call(Rack::MockRequest.env_for('http://unknown.com/')) }
        .to(raise_error(Apartment::TenantNotFound, /unknown\.com/))
    end

    it 'does not call the inner app when host is unknown' do
      called = false
      app = lambda { |_env|
        called = true
        [200, {}, ['ok']]
      }
      elevator = described_class.new(app, hash: { 'known.com' => 'acme' })
      expect { elevator.call(Rack::MockRequest.env_for('http://unknown.com/')) }
        .to(raise_error(Apartment::TenantNotFound))
      expect(called).to(be(false))
    end
  end
end
