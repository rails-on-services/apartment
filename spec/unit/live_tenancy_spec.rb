# frozen_string_literal: true

require 'spec_helper'
require 'action_controller'
require 'action_controller/metal/live'

RSpec.describe Apartment::LiveTenancy do
  # A minimal controller-like host that records around_action registration
  # and exposes the private callback method for direct invocation.
  let(:controller_class) do
    Class.new do
      attr_accessor :request

      def self.registered_around_actions
        @registered_around_actions ||= []
      end

      def self.around_action(name)
        registered_around_actions << name
      end

      include Apartment::LiveTenancy
    end
  end

  describe 'when included' do
    it 'registers an around_action callback' do
      expect(controller_class.registered_around_actions)
        .to(include(:_apartment_with_live_tenant))
    end
  end

  describe '#_apartment_with_live_tenant' do
    let(:instance) { controller_class.new }
    let(:env) { {} }

    before do
      instance.request = double('Request', env: env)
    end

    context 'when env carries Apartment::ENV_TENANT_KEY' do
      before { env[Apartment::ENV_TENANT_KEY] = 'acme' }

      it 'wraps the block in Apartment::Tenant.switch with the env tenant' do
        expect(Apartment::Tenant).to(receive(:switch).with('acme').and_yield)
        result = instance.send(:_apartment_with_live_tenant) { 42 }
        expect(result).to(eq(42))
      end
    end

    context 'when env has no tenant key' do
      it 'yields without calling Apartment::Tenant.switch' do
        expect(Apartment::Tenant).not_to(receive(:switch))
        result = instance.send(:_apartment_with_live_tenant) { 'plain' }
        expect(result).to(eq('plain'))
      end
    end

    context 'when the block raises' do
      before { env[Apartment::ENV_TENANT_KEY] = 'acme' }

      it 'propagates the exception (switch handles restore via its own ensure)' do
        allow(Apartment::Tenant).to(receive(:switch).with('acme').and_yield)
        expect do
          instance.send(:_apartment_with_live_tenant) { raise('boom') }
        end.to(raise_error('boom'))
      end
    end
  end
end
