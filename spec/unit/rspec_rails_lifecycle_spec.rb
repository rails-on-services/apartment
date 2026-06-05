# frozen_string_literal: true

require 'spec_helper'

# Regression guard for the rspec-rails interaction documented in
# docs/testing.md, section "Tenant context is reset before every rspec-rails
# example".
#
# Apartment::Current is an ActiveSupport::CurrentAttributes subclass. Every
# typed rspec-rails example group (RSpec::Rails::RailsExampleGroup, which backs
# model / request / controller / system / job specs) mixes in
# ActiveSupport::CurrentAttributes::TestHelper, whose #before_setup calls
# CurrentAttributes.clear_all. rspec-rails wires that #before_setup inside a
# group-level `around` hook (MinitestLifecycleAdapter), so Apartment::Current
# is reset at the start of every example.
#
# The gem's own suite is plain RSpec and never loads rspec-rails, so it would
# otherwise never exercise this. This spec reconstructs the lifecycle from the
# real rspec-rails modules and pins the behavior testing.md tells consumers to
# rely on: tenant context set in before(:each) survives to the example body;
# context set outside the per-example lifecycle (suite bootstrap, a global
# config.around) does not.
#
# Only the two adapter modules are required — not all of `rspec/rails`, which
# pulls ActionView matchers that need a booted Rails app. When rspec-rails is
# absent the spec skips; the dedicated CI job sets RSPEC_RAILS_REQUIRED so a
# skip there — where rspec-rails must be present — fails loudly instead.

rspec_rails_loaded =
  begin
    require('rspec/rails/adapters')
    require('active_support/current_attributes/test_helper')
    true
  rescue LoadError => e
    raise if ENV['RSPEC_RAILS_REQUIRED']

    warn "[rspec_rails_lifecycle_spec] skipping: #{e.message}"
    false
  end

if rspec_rails_loaded
  RSpec.describe('Apartment::Current under the rspec-rails example lifecycle') do
    it 'RailsExampleGroup composes the CurrentAttributes lifecycle' do
      # The composition the whole interaction rests on. rails_example_group.rb
      # cannot be loaded standalone (it pulls rspec/rails/matchers -> ActionView),
      # so this asserts against its source: if a future rspec-rails stops mixing
      # these modules into RailsExampleGroup, docs/testing.md's guidance is stale.
      gem_spec = Gem.loaded_specs['rspec-rails']
      raise('rspec-rails is loaded but not registered in Gem.loaded_specs') unless gem_spec

      source = File.read(File.join(
                           gem_spec.full_gem_path,
                           'lib/rspec/rails/example/rails_example_group.rb'
                         ))
      expect(source).to(include('ActiveSupport::CurrentAttributes::TestHelper'))
      expect(source).to(include('RSpec::Rails::MinitestLifecycleAdapter'))
    end

    # The two modules below, in this order, are what RailsExampleGroup mixes
    # into every typed example group. Including them directly reproduces the
    # real per-example lifecycle without booting a Rails app.
    context 'tenant context set in before(:each)' do
      include RSpec::Rails::MinitestLifecycleAdapter
      include ActiveSupport::CurrentAttributes::TestHelper

      before { Apartment::Current.tenant = 'set-in-before-each' }

      it 'survives the per-example reset' do
        expect(Apartment::Current.tenant).to(eq('set-in-before-each'))
      end
    end

    context 'tenant context set outside the per-example lifecycle' do
      # This around hook is registered before MinitestLifecycleAdapter is
      # included, so it nests outside the adapter's around — the analogue of
      # a suite-level switch! or a global config.around. before_setup ->
      # clear_all then runs inside example.run and wipes it.
      around do |example|
        Apartment::Current.tenant = 'set-outside-lifecycle'
        example.run
      end

      include RSpec::Rails::MinitestLifecycleAdapter
      include ActiveSupport::CurrentAttributes::TestHelper

      it 'is wiped before the example body' do
        expect(Apartment::Current.tenant).to(be_nil)
      end
    end

    context 'tenant context set in an around hook inside the example group' do
      include RSpec::Rails::MinitestLifecycleAdapter
      include ActiveSupport::CurrentAttributes::TestHelper

      # Registered after MinitestLifecycleAdapter, so this around nests
      # *inside* the adapter's around — it runs after before_setup ->
      # clear_all, the way an `around` written inside an example group does.
      around do |example|
        Apartment::Current.tenant = 'set-in-group-around'
        example.run
      end

      it 'survives the per-example reset' do
        expect(Apartment::Current.tenant).to(eq('set-in-group-around'))
      end
    end
  end
else
  RSpec.describe('Apartment::Current under the rspec-rails example lifecycle') do
    it('pins the rspec-rails CurrentAttributes lifecycle') { skip('requires rspec-rails') }
  end
end
