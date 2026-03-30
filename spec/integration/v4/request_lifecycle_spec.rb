# frozen_string_literal: true

# Request lifecycle tests require the dummy Rails app + real PostgreSQL.
# Run via: DATABASE_ENGINE=postgresql bundle exec appraisal rails-8.1-postgresql \
#   rspec spec/integration/v4/request_lifecycle_spec.rb

require 'spec_helper'

DUMMY_APP_AVAILABLE = begin
  require_relative('../../dummy/config/environment')
  require('rack/test')
  true
rescue LoadError, StandardError => e
  warn "[request_lifecycle_spec] Skipping: #{e.message}"
  false
end

RSpec.describe('v4 Request lifecycle', :request_lifecycle,
               skip: (DUMMY_APP_AVAILABLE ? false : 'requires dummy Rails app + PostgreSQL')) do
  include Rack::Test::Methods

  def app
    Rails.application
  end

  before(:all) do
    # Ensure test schemas exist
    %w[acme widgets].each do |tenant|
      Apartment.adapter.create(tenant)
      Apartment::Tenant.switch(tenant) do
        ActiveRecord::Base.connection.create_table(:users, force: true) do |t|
          t.string(:name)
        end
      end
    rescue Apartment::TenantExists
      nil
    end
  end

  after(:all) do
    %w[acme widgets].each do |tenant|
      Apartment.adapter.drop(tenant)
    rescue StandardError
      nil
    end
  end

  after do
    Apartment::Current.reset
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
    # After request completes, tenant should be reset to default
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
