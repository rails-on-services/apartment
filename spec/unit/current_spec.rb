# frozen_string_literal: true

require 'spec_helper'

RSpec.describe(Apartment::Current) do
  after { described_class.reset }

  it 'stores and retrieves the tenant attribute' do
    described_class.tenant = 'acme'
    expect(described_class.tenant).to(eq('acme'))
  end

  it 'stores and retrieves the previous_tenant attribute' do
    described_class.previous_tenant = 'old_tenant'
    expect(described_class.previous_tenant).to(eq('old_tenant'))
  end

  it 'resets all attributes' do
    described_class.tenant = 'acme'
    described_class.previous_tenant = 'old'
    described_class.reset

    expect(described_class.tenant).to(be_nil)
    expect(described_class.previous_tenant).to(be_nil)
  end

  it 'isolates state across threads' do
    described_class.tenant = 'main_thread'

    thread_value = Thread.new do
      described_class.tenant = 'other_thread'
      described_class.tenant
    end.value

    expect(described_class.tenant).to(eq('main_thread'))
    expect(thread_value).to(eq('other_thread'))
  end
end
