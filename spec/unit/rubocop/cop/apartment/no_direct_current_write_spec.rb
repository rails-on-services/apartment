# frozen_string_literal: true

require 'rubocop'
require 'rubocop/rspec/support'
require_relative '../../../../../lib/rubocop/cop/apartment/no_direct_current_write'

RSpec.describe(RuboCop::Cop::Apartment::NoDirectCurrentWrite, :config) do
  it 'flags a qualified Apartment::Current.tenant write' do
    expect_offense(<<~RUBY)
      Apartment::Current.tenant = 'acme'
                         ^^^^^^ Do not write `Apartment::Current.tenant` directly; use the block-form `Apartment::Tenant.switch(tenant) { ... }`.
    RUBY
  end

  it 'flags a qualified Apartment::Current.previous_tenant write' do
    expect_offense(<<~RUBY)
      Apartment::Current.previous_tenant = nil
                         ^^^^^^^^^^^^^^^ Do not write `Apartment::Current.previous_tenant` directly; use the block-form `Apartment::Tenant.switch(tenant) { ... }`.
    RUBY
  end

  it 'flags a cbase (::Apartment) write' do
    expect_offense(<<~RUBY)
      ::Apartment::Current.tenant = 'acme'
                           ^^^^^^ Do not write `Apartment::Current.tenant` directly; use the block-form `Apartment::Tenant.switch(tenant) { ... }`.
    RUBY
  end

  it 'flags an or-assign (||=) — the idiomatic set-if-unset bypass' do
    expect_offense(<<~RUBY)
      Apartment::Current.tenant ||= 'acme'
                         ^^^^^^ Do not write `Apartment::Current.tenant` directly; use the block-form `Apartment::Tenant.switch(tenant) { ... }`.
    RUBY
  end

  it 'flags an and-assign (&&=) to previous_tenant' do
    expect_offense(<<~RUBY)
      Apartment::Current.previous_tenant &&= 'x'
                         ^^^^^^^^^^^^^^^ Do not write `Apartment::Current.previous_tenant` directly; use the block-form `Apartment::Tenant.switch(tenant) { ... }`.
    RUBY
  end

  it 'flags an op-assign (+=) to tenant' do
    expect_offense(<<~RUBY)
      Apartment::Current.tenant += 'x'
                         ^^^^^^ Do not write `Apartment::Current.tenant` directly; use the block-form `Apartment::Tenant.switch(tenant) { ... }`.
    RUBY
  end

  it 'ignores the block-form switch' do
    expect_no_offenses("Apartment::Tenant.switch('acme') { :work }")
  end

  it 'ignores a read of Apartment::Current.tenant' do
    expect_no_offenses('x = Apartment::Current.tenant')
  end

  it 'ignores an unrelated Current constant' do
    expect_no_offenses("Foo::Current.tenant = 'x'")
    expect_no_offenses("Current.tenant = 'x'")
    expect_no_offenses("Foo::Current.tenant ||= 'x'")
  end

  it 'respects an inline disable' do
    expect_no_offenses(<<~RUBY)
      Apartment::Current.tenant = 'x' # rubocop:disable Apartment/NoDirectCurrentWrite
    RUBY
  end
end
