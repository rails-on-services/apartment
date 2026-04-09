# frozen_string_literal: true

require 'spec_helper'

# Railtie loads automatically when Rails is present (via lib/apartment.rb).
# Without Rails, Apartment::Railtie is not defined — skip gracefully.
RSpec.describe('Apartment::Railtie') do
  before do
    skip 'requires Rails (run via appraisal)' unless defined?(Apartment::Railtie)
  end

  describe '.resolve_elevator_class' do
    it 'resolves :subdomain to Apartment::Elevators::Subdomain' do
      klass = Apartment::Railtie.resolve_elevator_class(:subdomain)
      expect(klass).to(eq(Apartment::Elevators::Subdomain))
    end

    it 'resolves :domain to Apartment::Elevators::Domain' do
      klass = Apartment::Railtie.resolve_elevator_class(:domain)
      expect(klass).to(eq(Apartment::Elevators::Domain))
    end

    it 'resolves :host to Apartment::Elevators::Host' do
      klass = Apartment::Railtie.resolve_elevator_class(:host)
      expect(klass).to(eq(Apartment::Elevators::Host))
    end

    it 'raises ConfigurationError for unknown elevator' do
      expect { Apartment::Railtie.resolve_elevator_class(:nonexistent) }
        .to(raise_error(Apartment::ConfigurationError, /Unknown elevator.*nonexistent/))
    end

    it 'includes available elevators in the error message' do
      expect { Apartment::Railtie.resolve_elevator_class(:nonexistent) }
        .to(raise_error(Apartment::ConfigurationError, /subdomain/))
    end

    it 'passes through a class without resolution' do
      klass = Apartment::Railtie.resolve_elevator_class(Apartment::Elevators::Subdomain)
      expect(klass).to(eq(Apartment::Elevators::Subdomain))
    end

    it 'passes through any custom class' do
      custom_class = Class.new(Apartment::Elevators::Generic)
      klass = Apartment::Railtie.resolve_elevator_class(custom_class)
      expect(klass).to(eq(custom_class))
    end

    it 'resolves :header to Apartment::Elevators::Header' do
      klass = Apartment::Railtie.resolve_elevator_class(:header)
      expect(klass).to(eq(Apartment::Elevators::Header))
    end
  end

  describe '.insert_elevator_middleware' do
    let(:middleware_stack) { double('MiddlewareStack') }
    let(:elevator_class) { Apartment::Elevators::Subdomain }

    before do
      Apartment.configure do |config|
        config.tenant_strategy = :schema
        config.tenants_provider = -> { [] }
        config.elevator = :subdomain
      end
    end

    it 'appends with use when insert_before is nil' do
      expect(middleware_stack).to(receive(:use).with(elevator_class))
      Apartment::Railtie.insert_elevator_middleware(middleware_stack, elevator_class)
    end

    it 'appends with use and forwards kwargs when insert_before is nil' do
      expect(middleware_stack).to(receive(:use).with(elevator_class, foo: :bar))
      Apartment::Railtie.insert_elevator_middleware(middleware_stack, elevator_class, foo: :bar)
    end

    it 'inserts before the specified middleware' do
      expect(middleware_stack).to(receive(:insert_before).with('Warden::Manager', elevator_class))
      Apartment::Railtie.insert_elevator_middleware(
        middleware_stack, elevator_class, insert_before: 'Warden::Manager'
      )
    end

    it 'inserts before a Class target' do
      target_class = Class.new
      expect(middleware_stack).to(receive(:insert_before).with(target_class, elevator_class))
      Apartment::Railtie.insert_elevator_middleware(
        middleware_stack, elevator_class, insert_before: target_class
      )
    end

    it 'forwards kwargs when using insert_before' do
      expect(middleware_stack).to(receive(:insert_before).with('ActionDispatch::Session', elevator_class, foo: :bar))
      Apartment::Railtie.insert_elevator_middleware(
        middleware_stack, elevator_class, insert_before: 'ActionDispatch::Session', foo: :bar
      )
    end

    it 'wraps RuntimeError from insert_before as ConfigurationError' do
      allow(middleware_stack).to(receive(:insert_before).and_raise(RuntimeError, 'No such middleware'))
      expect do
        Apartment::Railtie.insert_elevator_middleware(
          middleware_stack, elevator_class, insert_before: 'NonExistent::Middleware'
        )
      end.to(raise_error(Apartment::ConfigurationError, /elevator_insert_before.*NonExistent::Middleware/))
    end
  end

  describe '.header_trust_warning?' do
    it 'returns true for Header with trusted: false' do
      expect(Apartment::Railtie.header_trust_warning?(Apartment::Elevators::Header, {})).to(be(true))
    end

    it 'returns false for Header with trusted: true' do
      expect(Apartment::Railtie.header_trust_warning?(Apartment::Elevators::Header, { trusted: true })).to(be(false))
    end

    it 'returns true for Header subclass with trusted: false' do
      subclass = Class.new(Apartment::Elevators::Header)
      expect(Apartment::Railtie.header_trust_warning?(subclass, {})).to(be(true))
    end

    it 'returns false for non-Header elevator' do
      expect(Apartment::Railtie.header_trust_warning?(Apartment::Elevators::Subdomain, {})).to(be(false))
    end
  end
end
