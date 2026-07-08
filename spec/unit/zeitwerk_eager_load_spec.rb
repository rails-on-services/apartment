# frozen_string_literal: true

require 'spec_helper'

# Regression guard for the v4.0.0.alpha5 boot crash. apartment's own
# `Zeitwerk::Loader.for_gem` manages the whole lib/ tree. When a host app sets
# `config.eager_load = true` (production/CI), Rails runs
# `Zeitwerk::Loader.eager_load_all`, which eager-loads every registered gem
# loader — apartment's included — and raised Zeitwerk::NameError on
# lib/generators, a Rails generator whose constant (Apartment::InstallGenerator)
# does not match Zeitwerk's path inference. lib/apartment.rb must keep that
# directory ignored.
#
# This asserts the ignore *structurally* rather than by eager-loading the shared
# loader. Calling eager_load(force: true) here would (a) pass vacuously if the
# offending generator file were ever removed, and (b) permanently force-load the
# whole gem tree, making other specs' lazy-autoload assumptions order-dependent.
# The structural check fails precisely when the `loader.ignore(".../generators")`
# line is dropped — which is the regression we care about.
RSpec.describe('Zeitwerk gem loader') do
  # apartment.rb keeps its for_gem loader in a local, so retrieve it from the
  # registry (where for_gem registers it). `each` is the minimal, stable surface
  # of Zeitwerk::Registry.loaders; the `not_to be_nil` guard below turns any
  # future Zeitwerk API drift into a loud failure rather than a vacuous pass.
  def apartment_loader
    lib_dir = File.expand_path('../../lib', __dir__)
    found = nil
    Zeitwerk::Registry.loaders.each { |loader| found = loader if loader.dirs.include?(lib_dir) }
    found
  end

  it 'ignores lib/generators so host-app eager loading does not raise' do
    loader = apartment_loader
    expect(loader).not_to(be_nil)

    generators_dir = File.expand_path('../../lib/generators', __dir__)
    # __ignores? is Zeitwerk's public predicate for "is this path ignored?",
    # present across apartment's supported Zeitwerk range (2.7.x and 2.8.x).
    expect(loader.__ignores?(generators_dir)).to(be(true))
  end
end
