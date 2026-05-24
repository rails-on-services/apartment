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

    it 'inserts after ActionDispatch::Callbacks' do
      expect(middleware_stack).to(receive(:insert_after).with(ActionDispatch::Callbacks, elevator_class))
      Apartment::Railtie.insert_elevator_middleware(middleware_stack, elevator_class)
    end

    it 'forwards kwargs to insert_after' do
      expect(middleware_stack).to(
        receive(:insert_after).with(ActionDispatch::Callbacks, elevator_class, foo: :bar)
      )
      Apartment::Railtie.insert_elevator_middleware(middleware_stack, elevator_class, foo: :bar)
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

  describe '.deactivate_pool_reaper_in_test_env!' do
    it 'stops Apartment.pool_reaper when Rails.env.test? is true' do
      reaper = instance_double(Apartment::PoolReaper, stop: nil)
      allow(Apartment).to(receive(:pool_reaper).and_return(reaper))
      allow(Rails).to(receive(:env).and_return(ActiveSupport::StringInquirer.new('test')))

      Apartment::Railtie.deactivate_pool_reaper_in_test_env!

      expect(reaper).to(have_received(:stop))
    end

    it 'emits reaper_stopped.apartment with reason :test_env when it stops the reaper' do
      reaper = instance_double(Apartment::PoolReaper, stop: nil)
      allow(Apartment).to(receive(:pool_reaper).and_return(reaper))
      allow(Rails).to(receive(:env).and_return(ActiveSupport::StringInquirer.new('test')))
      events = []
      sub = ActiveSupport::Notifications.subscribe('reaper_stopped.apartment') { |e| events << e }

      Apartment::Railtie.deactivate_pool_reaper_in_test_env!

      expect(events.size).to(eq(1))
      expect(events.first.payload).to(eq(reason: :test_env))
    ensure
      ActiveSupport::Notifications.unsubscribe(sub) if sub
    end

    it 'does nothing outside the test environment' do
      reaper = instance_double(Apartment::PoolReaper, stop: nil)
      allow(Apartment).to(receive(:pool_reaper).and_return(reaper))
      allow(Rails).to(receive(:env).and_return(ActiveSupport::StringInquirer.new('production')))

      Apartment::Railtie.deactivate_pool_reaper_in_test_env!

      expect(reaper).not_to(have_received(:stop))
    end

    it 'is a no-op when no reaper is configured' do
      allow(Apartment).to(receive(:pool_reaper).and_return(nil))
      allow(Rails).to(receive(:env).and_return(ActiveSupport::StringInquirer.new('test')))

      expect { Apartment::Railtie.deactivate_pool_reaper_in_test_env! }.not_to(raise_error)
    end
  end

  describe 'TenantNotFound rescue_responses mapping' do
    # Unit specs do not boot a Rails::Application, so railtie initializers
    # never run on their own — invoke the initializer block directly.
    it 'maps Apartment::TenantNotFound to :not_found' do
      require 'action_dispatch'
      initializer = Apartment::Railtie.initializers.find { |i| i.name == 'apartment.rescue_responses' }
      expect(initializer).not_to(be_nil)

      initializer.run

      expect(ActionDispatch::ExceptionWrapper.rescue_responses['Apartment::TenantNotFound'])
        .to(eq(:not_found))
    end
  end
end
