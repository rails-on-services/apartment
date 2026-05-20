# frozen_string_literal: true

# Request lifecycle tests require the dummy Rails app + real PostgreSQL.
# Run via: DATABASE_ENGINE=postgresql bundle exec appraisal rails-8.1-postgresql \
#   rspec spec/integration/v4/request_lifecycle_spec.rb

require 'spec_helper'
require_relative 'support'

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
  # app's own initializer), activate!, and Tenant.init. Configuring alone is
  # not enough — clear_config also drops the adapter and unsets @activated.
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

    # force: true gives each example a clean users table — clear_config does
    # not truncate, so without this rows would leak between examples. The
    # default tenant is included: a request with no subdomain falls through
    # to it, and the controller still calls User.count.
    [Apartment.config.default_tenant, *test_tenants].each do |tenant|
      Apartment::Tenant.switch(tenant) do
        ActiveRecord::Base.connection.create_table(:users, force: true) do |t|
          t.string(:name)
        end
      end
    end
  end

  after { Apartment::Current.reset }

  after(:all) do
    establish_apartment! unless Apartment.config
    test_tenants.each do |tenant|
      Apartment.adapter.drop(tenant)
    rescue StandardError
      nil
    end
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
  end

  it 'tenant context is cleaned up after request' do
    header 'Host', 'acme.example.com'
    get '/tenant_info'
    # The executor resets Apartment::Current after the request; Tenant.current
    # then falls back to default_tenant.
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
