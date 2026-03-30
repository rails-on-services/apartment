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
  end
end
