# frozen_string_literal: true

require 'spec_helper'

describe Apartment do
  it 'is valid' do
    expect(described_class).to(be_a(Module))
  end

  it 'is a valid app' do
    expect(Rails.application).to(be_a(Dummy::Application))
  end
end
