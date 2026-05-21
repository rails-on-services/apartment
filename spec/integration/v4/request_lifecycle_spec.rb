# frozen_string_literal: true

# Request lifecycle tests require the dummy Rails app + real PostgreSQL.
# Run via: DATABASE_ENGINE=postgresql bundle exec appraisal rails-8.1-postgresql \
#   rspec spec/integration/v4/request_lifecycle_spec.rb

require 'spec_helper'
require_relative 'support'

# The dummy app's database.yml only defines a `test` environment; pin RAILS_ENV
# so the spec boots that environment regardless of how it was invoked.
ENV['RAILS_ENV'] ||= 'test'

# CI's PostgreSQL job sets REQUEST_LIFECYCLE_REQUIRED so a missing dummy app or
# rack-test fails the build loudly. This spec silently skipped in CI for months
# once rack-test fell out of the appraisal gemfiles; the flag makes that visible.
DUMMY_APP_AVAILABLE = begin
  require_relative('../../dummy/config/environment')
  require('rack/test')
  true
rescue LoadError, StandardError => e
  raise if ENV['REQUEST_LIFECYCLE_REQUIRED']

  warn "[request_lifecycle_spec] Skipping: #{e.message}"
  false
end

RSpec.describe(
  'v4 Request lifecycle', :request_lifecycle,
  skip: (DUMMY_APP_AVAILABLE && V4IntegrationHelper.postgresql? ? false : 'requires dummy Rails app + PostgreSQL')
) do
  include Rack::Test::Methods

  def app
    Rails.application
  end

  def test_tenants = %w[acme widgets]

  # spec_helper.rb clears Apartment.config after every example. The dummy app
  # configures Apartment once, at boot — so each example must re-establish the
  # full state the railtie's after_initialize path sets up: configure (via the
  # app's own initializer), then activate! and Tenant.init. clear_config tears
  # down everything (config, adapter, pools, reaper, @activated), so re-running
  # the initializer's Apartment.configure alone would leave the suite half-booted.
  def establish_apartment!
    load(Rails.root.join('config/initializers/apartment.rb'))
    Apartment.activate!
    Apartment::Tenant.init
  end

  before do
    establish_apartment!

    test_tenants.each do |tenant|
      Apartment.adapter.create(tenant)
    rescue Apartment::TenantExists
      nil
    end

    # Each example needs a clean users table per tenant: clear_config does not
    # truncate, so force: true drops and recreates. The name MUST be schema-
    # qualified. Tenant schemas (acme, widgets) carry `public` in their
    # search_path so persistent/pinned tables stay visible — which makes an
    # unqualified force-drop dangerous: `DROP TABLE users` resolves through the
    # search_path and, before a tenant's own users table exists, lands on
    # public.users, destroying the default tenant's table that an earlier loop
    # iteration just created. The default tenant is included because a
    # no-subdomain request falls through to it and the controller calls User.count.
    [Apartment.config.default_tenant, *test_tenants].each do |tenant|
      Apartment::Tenant.switch(tenant) do
        ActiveRecord::Base.connection.create_table("#{tenant}.users", force: true) do |t|
          t.string(:name)
        end
      end
    end
  end

  after { Apartment::Current.reset }

  after(:all) do
    # The per-example `after` cleared config; re-establish to drop the test
    # tenants and the default tenant's users table, then clear config so this
    # spec leaves no Apartment state (config, pools, a running reaper) behind
    # for whatever spec file runs next.
    establish_apartment!
    test_tenants.each do |tenant|
      Apartment.adapter.drop(tenant)
    rescue StandardError
      nil
    end
    Apartment::Tenant.switch(Apartment.config.default_tenant) do
      ActiveRecord::Base.connection.drop_table(:users, if_exists: true)
    end
  ensure
    Apartment.clear_config
    Apartment::Current.reset
  end

  it 'inserts the elevator middleware into the application stack' do
    # The elevator is inserted once, when the dummy app boots — this asserts
    # that boot-time wiring, not anything the per-example `before` rebuilds.
    # Pins the railtie's initializer-ordering fix directly: a regression
    # fails here, not via a downstream routing symptom.
    expect(Rails.application.middleware.map(&:name))
      .to(include('Apartment::Elevators::Subdomain'))
  end

  it 'elevator switches tenant based on subdomain' do
    header 'Host', 'acme.example.com'
    get '/tenant_info'
    expect(last_response).to(be_ok)
    body = JSON.parse(last_response.body)
    expect(body['tenant']).to(eq('acme'))
  end

  it 'data is isolated between tenants' do
    Apartment::Tenant.switch('acme') { User.create!(name: 'Alice') }

    header 'Host', 'acme.example.com'
    get '/tenant_info'
    expect(JSON.parse(last_response.body)['user_count']).to(eq(1))

    header 'Host', 'widgets.example.com'
    get '/tenant_info'
    expect(JSON.parse(last_response.body)['user_count']).to(eq(0))

    # Switching back must still see acme's row — a pool-leak regression
    # (the failure mode v4's pool-per-tenant model exists to prevent) would
    # drop the count or cross tenants.
    header 'Host', 'acme.example.com'
    get '/tenant_info'
    expect(JSON.parse(last_response.body)['user_count']).to(eq(1))
  end

  it 'tenant context is cleaned up after request' do
    header 'Host', 'acme.example.com'
    get '/tenant_info'
    # Rails' executor resets all CurrentAttributes (Apartment::Current
    # included) after the request; Tenant.current then falls back to
    # default_tenant.
    expect(Apartment::Tenant.current).to(eq('public'))
  end

  it 'returns default tenant for requests without subdomain' do
    header 'Host', 'example.com'
    get '/tenant_info'
    expect(last_response).to(be_ok)
    body = JSON.parse(last_response.body)
    expect(body['tenant']).to(eq('public'))
  end
end
