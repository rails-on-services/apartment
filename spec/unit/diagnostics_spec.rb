# frozen_string_literal: true

require 'spec_helper'
require 'logger'
require 'stringio'

RSpec.describe(Apartment::Diagnostics) do
  let(:log_io) { StringIO.new }
  let(:logger) { Logger.new(log_io).tap { |l| l.level = Logger::DEBUG } }
  let(:fake_model_class) { Struct.new(:name).new('FakeWidget') }

  before do
    Apartment.configure do |config|
      config.tenant_strategy = :schema
      config.tenants_provider = -> { [] }
      config.default_tenant = 'public'
      config.log_default_tenant_fallback = true
    end
    stub_const('Rails', Module.new)
    allow(Rails).to(receive(:logger).and_return(logger))
    described_class.reset!
  end

  after { described_class.reset! }

  # Build a small caller_locations array. Real `Thread::Backtrace::Location`
  # objects are hard to construct synthetically; the module only uses
  # #path, #lineno, and #label, so a struct standing in is enough.
  def frame(path:, lineno:, label: 'block')
    Struct.new(:path, :lineno, :label).new(path, lineno, label)
  end

  describe '.record_default_tenant_fallback' do
    it 'is a no-op when Apartment.config is nil' do
      Apartment.clear_config
      described_class.record_default_tenant_fallback(
        fake_model_class,
        [frame(path: '/app/models/widget.rb', lineno: 42)]
      )
      expect(log_io.string).to(be_empty)
    end

    it 'is a no-op when the flag is off' do
      # Config is frozen after configure; reconfigure instead of mutating.
      Apartment.configure do |config|
        config.tenant_strategy = :schema
        config.tenants_provider = -> { [] }
        config.default_tenant = 'public'
        config.log_default_tenant_fallback = false
      end
      described_class.record_default_tenant_fallback(
        fake_model_class,
        [frame(path: '/app/models/widget.rb', lineno: 42)]
      )
      expect(log_io.string).to(be_empty)
    end

    it 'is a no-op when Rails.logger is missing' do
      allow(Rails).to(receive(:logger).and_return(nil))
      described_class.record_default_tenant_fallback(
        fake_model_class,
        [frame(path: '/app/models/widget.rb', lineno: 42)]
      )
      # Without a logger, dedup state should also not be polluted.
      expect(described_class.seen_sites).to(be_empty)
    end

    it 'logs at debug level with the model class and caller site' do
      described_class.record_default_tenant_fallback(
        fake_model_class,
        [frame(path: '/app/models/widget.rb', lineno: 42, label: 'load_async')]
      )
      expect(log_io.string).to(match(/DEBUG/))
      expect(log_io.string).to(match(/\[Apartment\] tenant=nil/))
      expect(log_io.string).to(match(/Model=FakeWidget/))
      expect(log_io.string).to(match(%r{Caller=/app/models/widget\.rb:42}))
    end

    it 'logs the first 8 caller frames' do
      frames = (1..12).map { |i| frame(path: '/app/work.rb', lineno: i) }
      described_class.record_default_tenant_fallback(fake_model_class, frames)
      lines_after_caller = log_io.string.scan(%r{/app/work\.rb:\d+:in `block'})
      # Cap at 8 even though we passed 12.
      expect(lines_after_caller.size).to(eq(8))
    end

    it 'dedupes per call site so a hot loop logs once' do
      f = [frame(path: '/app/models/widget.rb', lineno: 99)]
      5.times { described_class.record_default_tenant_fallback(fake_model_class, f) }
      expect(log_io.string.scan('[Apartment] tenant=nil').size).to(eq(1))
    end

    it 'logs distinct call sites separately' do
      a = [frame(path: '/app/models/widget.rb', lineno: 10)]
      b = [frame(path: '/app/models/widget.rb', lineno: 20)]
      described_class.record_default_tenant_fallback(fake_model_class, a)
      described_class.record_default_tenant_fallback(fake_model_class, b)
      expect(log_io.string.scan('[Apartment] tenant=nil').size).to(eq(2))
    end

    it 'skips gem-internal frames (apartment + Rails core) to reach user code' do
      frames = [
        frame(path: '/gems/apartment-4.0.0/lib/apartment/patches/connection_handling.rb', lineno: 22),
        frame(path: '/gems/activerecord-8.1.3/lib/active_record/relation.rb', lineno: 1437),
        frame(path: '/gems/activesupport-8.1.3/lib/active_support/callbacks.rb', lineno: 99),
        frame(path: '/app/controllers/posts_controller.rb', lineno: 17, label: 'show'),
      ]
      described_class.record_default_tenant_fallback(fake_model_class, frames)
      expect(log_io.string).to(match(%r{Caller=/app/controllers/posts_controller\.rb:17}))
    end

    # Regression: panel review of #417 caught that a substring match on
    # "apartment" would filter user apps whose path contains that word --
    # e.g., an app called "my-apartment-service". The fix uses the gem's
    # own __dir__ as the prefix for source paths and an anchored
    # `/gems/apartment-<digit>` pattern for installed gem paths, so
    # adopter app paths cannot collide.
    it 'does NOT filter user app paths that happen to contain the word "apartment"' do
      frames = [
        frame(path: '/gems/activerecord-8.1.3/lib/active_record/relation.rb', lineno: 1437),
        frame(path: '/Users/dev/my-apartment-service/app/models/post.rb', lineno: 12, label: 'recent'),
      ]
      described_class.record_default_tenant_fallback(fake_model_class, frames)
      expect(log_io.string).to(match(%r{Caller=/Users/dev/my-apartment-service/app/models/post\.rb:12}))
    end

    # Regression: don't over-filter non-core gems with Rails-sounding
    # names. If a leak comes from active_model_serializers or activeadmin,
    # the user wants to see that line, not have it hidden behind AR.
    it 'does NOT filter non-core Rails-ecosystem gems' do
      frames = [
        frame(path: '/gems/activerecord-8.1.3/lib/active_record/relation.rb', lineno: 1437),
        frame(path: '/gems/active_model_serializers-0.10.14/lib/active_model/serializer.rb', lineno: 89),
        frame(path: '/app/controllers/posts_controller.rb', lineno: 17),
      ]
      described_class.record_default_tenant_fallback(fake_model_class, frames)
      # First non-core, non-apartment frame is the serializer.
      expect(log_io.string).to(match(%r{Caller=/gems/active_model_serializers-0\.10\.14/lib/active_model/serializer\.rb:89}))
    end

    it 'falls back to the topmost frame when every frame is internal' do
      frames = [
        frame(path: '/gems/apartment-4.0.0/lib/apartment/patches/connection_handling.rb', lineno: 22),
        frame(path: '/gems/activerecord-8.1.3/lib/active_record/relation.rb', lineno: 1437),
      ]
      described_class.record_default_tenant_fallback(fake_model_class, frames)
      expect(log_io.string).to(match(%r{Caller=/gems/apartment-4\.0\.0/lib/apartment/patches/connection_handling\.rb:22}))
    end
  end

  describe '.reset!' do
    it 'clears the dedup set so the next call logs again' do
      f = [frame(path: '/app/models/widget.rb', lineno: 5)]
      described_class.record_default_tenant_fallback(fake_model_class, f)
      described_class.reset!
      described_class.record_default_tenant_fallback(fake_model_class, f)
      expect(log_io.string.scan('[Apartment] tenant=nil').size).to(eq(2))
    end
  end

  describe '.seen_sites' do
    it 'returns the set of recorded sites' do
      described_class.record_default_tenant_fallback(
        fake_model_class,
        [frame(path: '/app/foo.rb', lineno: 1)]
      )
      expect(described_class.seen_sites).to(include('/app/foo.rb:1'))
    end

    it 'returns a copy (mutation does not affect internal state)' do
      described_class.record_default_tenant_fallback(
        fake_model_class,
        [frame(path: '/app/foo.rb', lineno: 1)]
      )
      described_class.seen_sites.clear
      expect(described_class.seen_sites).not_to(be_empty)
    end
  end
end
