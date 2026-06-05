# frozen_string_literal: true

require 'rubocop'
require 'rubocop/rspec/support'
require_relative '../../../../../lib/rubocop/cop/apartment/prefer_block_switch'

RSpec.describe(RuboCop::Cop::Apartment::PreferBlockSwitch, :config) do
  it 'flags Apartment::Tenant.switch!' do
    expect_offense(<<~RUBY)
      Apartment::Tenant.switch!('acme')
                        ^^^^^^^ Use the block-form `Apartment::Tenant.switch(tenant) { ... }` instead of `switch!`.
    RUBY
  end

  it 'flags a cbase (::Apartment) switch!' do
    expect_offense(<<~RUBY)
      ::Apartment::Tenant.switch!('acme')
                          ^^^^^^^ Use the block-form `Apartment::Tenant.switch(tenant) { ... }` instead of `switch!`.
    RUBY
  end

  it 'ignores the block-form switch' do
    expect_no_offenses("Apartment::Tenant.switch('acme') { :work }")
  end

  it 'ignores reset' do
    expect_no_offenses('Apartment::Tenant.reset')
  end

  it 'ignores switch! on an unrelated receiver' do
    expect_no_offenses("Foo::Tenant.switch!('x')")
  end

  it 'respects an inline disable' do
    expect_no_offenses(<<~RUBY)
      Apartment::Tenant.switch!('x') # rubocop:disable Apartment/PreferBlockSwitch
    RUBY
  end
end
