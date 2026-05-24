# frozen_string_literal: true

require 'spec_helper'
require 'apartment/patches/live_tenant_propagation'

RSpec.describe(Apartment::Patches::LiveTenantPropagation) do
  let(:controller) do
    Class.new do
      def new_controller_thread
        yield
      end

      prepend Apartment::Patches::LiveTenantPropagation
    end.new
  end

  after { Apartment::Current.reset }

  it 'sets tenant thread variable during block execution' do
    Apartment::Current.tenant = 'acme'

    tenant_during = nil
    controller.new_controller_thread do
      tenant_during = Thread.current.thread_variable_get(:apartment_current_tenant)
    end

    expect(tenant_during).to(eq('acme'))
  end

  it 'clears tenant thread variable after completion' do
    Apartment::Current.tenant = 'acme'

    controller.new_controller_thread {}

    expect(Thread.current.thread_variable_get(:apartment_current_tenant)).to(be_nil)
  end
end
