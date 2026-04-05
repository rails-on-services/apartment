# frozen_string_literal: true

require 'spec_helper'
require 'active_support/tagged_logging'

RSpec.describe('Apartment::Tenant.switch tagged logging') do
  let(:output) { StringIO.new }
  let(:logger) { ActiveSupport::TaggedLogging.new(ActiveSupport::Logger.new(output)) }

  # Provide a minimal Rails.logger for unit testing without booting Rails.
  before do
    stub_const('Rails', Module.new) unless defined?(Rails)
    unless Rails.respond_to?(:logger)
      Rails.define_singleton_method(:logger) { @_test_logger }
      Rails.define_singleton_method(:logger=) { |l| @_test_logger = l }
    end
    @original_logger = Rails.logger
    Rails.logger = logger
  end

  after do
    Rails.logger = @original_logger
  end

  context 'when active_record_log is true' do
    before do
      Apartment.configure do |config|
        config.tenant_strategy = :schema
        config.tenants_provider = -> { [] }
        config.active_record_log = true
      end
    end

    it 'tags log output with the tenant name during the switch block' do
      Apartment::Tenant.switch('acme') do
        Rails.logger.info('inside switch')
      end

      expect(output.string).to(include('[acme]'))
      expect(output.string).to(include('inside switch'))
    end

    it 'removes the tag after the switch block completes' do
      Apartment::Tenant.switch('acme') do
        Rails.logger.info('inside')
      end

      output.truncate(0)
      output.rewind
      Rails.logger.info('outside')

      expect(output.string).not_to(include('[acme]'))
    end

    it 'handles nested switches with correct tags' do
      Apartment::Tenant.switch('acme') do
        Apartment::Tenant.switch('widgets') do
          Rails.logger.info('inner')
        end
        Rails.logger.info('outer')
      end

      lines = output.string.split("\n")
      expect(lines[0]).to(include('[widgets]'))
      expect(lines[0]).to(include('inner'))
      expect(lines[1]).to(include('[acme]'))
      expect(lines[1]).not_to(include('[widgets]'))
    end
  end

  context 'when active_record_log is false' do
    before do
      Apartment.configure do |config|
        config.tenant_strategy = :schema
        config.tenants_provider = -> { [] }
        config.active_record_log = false
      end
    end

    it 'does not tag log output' do
      Apartment::Tenant.switch('acme') do
        Rails.logger.info('no tag expected')
      end

      expect(output.string).not_to(include('[acme]'))
      expect(output.string).to(include('no tag expected'))
    end
  end

  context 'when logger does not support tagged' do
    let(:plain_logger) { ActiveSupport::Logger.new(output) }

    before do
      Apartment.configure do |config|
        config.tenant_strategy = :schema
        config.tenants_provider = -> { [] }
        config.active_record_log = true
      end
      Rails.logger = plain_logger
    end

    it 'does not raise and passes through' do
      expect do
        Apartment::Tenant.switch('acme') do
          Rails.logger.info('plain logger')
        end
      end.not_to(raise_error)

      expect(output.string).to(include('plain logger'))
    end
  end
end
