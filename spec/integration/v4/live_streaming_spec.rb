# frozen_string_literal: true

# Live streaming + tenant propagation requires the dummy Rails app + real
# PostgreSQL (the dummy app's database.yml is PG-only). Modeled on
# request_lifecycle_spec.rb.
#
# Run via:
#   DATABASE_ENGINE=postgresql bundle exec appraisal rails-8.1-postgresql \
#     rspec spec/integration/v4/live_streaming_spec.rb

require 'spec_helper'
require_relative 'support'

ENV['RAILS_ENV'] ||= 'test'

LIVE_STREAMING_DUMMY_AVAILABLE = begin
  require_relative('../../dummy/config/environment')
  require('rack/test')
  require('json')
  true
rescue LoadError, StandardError => e
  raise if ENV['REQUEST_LIFECYCLE_REQUIRED']

  warn "[live_streaming_spec] Skipping: #{e.message}"
  false
end

RSpec.describe(
  'ActionController::Live tenant propagation', :integration, :request_lifecycle,
  skip: (LIVE_STREAMING_DUMMY_AVAILABLE && V4IntegrationHelper.postgresql? ? false : 'requires dummy Rails app + PostgreSQL')
) do
  include Rack::Test::Methods

  def app
    Rails.application
  end

  def test_tenants = %w[acme widgets]

  def establish_apartment!
    load(Rails.root.join('config/initializers/apartment.rb'))
    Apartment.activate!
    Apartment::Tenant.init
  end

  def stream_payload(response)
    JSON.parse(response.body.sub(/\Adata:\s*/, '').strip)
  end

  before do
    establish_apartment!

    test_tenants.each do |tenant|
      Apartment.adapter.create(tenant)
    rescue Apartment::TenantExists
      nil
    end

    [Apartment.config.default_tenant, *test_tenants].each do |tenant|
      Apartment::Tenant.switch(tenant) do
        ActiveRecord::Base.connection.create_table(:users, force: true) do |t|
          t.string(:name)
        end
      end
    end

    Apartment::Tenant.switch('acme') do
      User.create!(name: 'A')
      User.create!(name: 'B')
      User.create!(name: 'C')
    end
    Apartment::Tenant.switch('widgets') { User.create!(name: 'X') }
  end

  after { Apartment::Current.reset }

  after(:all) do
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

  shared_examples 'propagates tenant into the Live stream' do
    it 'streams the acme tenant (3 users) inside response.stream.write' do
      header 'Host', 'acme.example.com'
      get '/stream'
      expect(last_response).to(be_ok)
      data = stream_payload(last_response)
      expect(data['tenant']).to(eq('acme'))
      expect(data['user_count']).to(eq(3))
    end

    it 'streams the widgets tenant (1 user) inside response.stream.write' do
      header 'Host', 'widgets.example.com'
      get '/stream'
      expect(last_response).to(be_ok)
      data = stream_payload(last_response)
      expect(data['tenant']).to(eq('widgets'))
      expect(data['user_count']).to(eq(1))
    end
  end

  context 'under :thread isolation' do
    around do |example|
      original = ActiveSupport::IsolatedExecutionState.isolation_level
      ActiveSupport::IsolatedExecutionState.isolation_level = :thread
      example.run
    ensure
      ActiveSupport::IsolatedExecutionState.isolation_level = original
    end

    include_examples 'propagates tenant into the Live stream'
  end
end
