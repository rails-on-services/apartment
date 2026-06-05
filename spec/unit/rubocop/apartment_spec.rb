# frozen_string_literal: true

require 'rubocop'
require_relative '../../../lib/rubocop/apartment'

RSpec.describe('rubocop/apartment') do
  it 'registers both Apartment cops' do
    names = RuboCop::Cop::Registry.global.cops.map(&:cop_name)
    expect(names).to(include('Apartment/NoDirectCurrentWrite', 'Apartment/PreferBlockSwitch'))
  end

  it 'config/default.yml sets the documented severities' do
    config = RuboCop::ConfigLoader.load_file('config/default.yml')
    expect(config['Apartment/NoDirectCurrentWrite']['Severity']).to(eq('error'))
    expect(config['Apartment/PreferBlockSwitch']['Severity']).to(eq('warning'))
    expect(config['Apartment/NoDirectCurrentWrite']['Enabled']).to(be(true))
    expect(config['Apartment/PreferBlockSwitch']['Enabled']).to(be(true))
  end
end
