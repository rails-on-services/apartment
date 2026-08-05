# frozen_string_literal: true

require 'spec_helper'

# Exercises the real ActiveRecord classes, not stand-ins: the whole point of the
# patch is that AR's connection registry has a specific unsynchronized shape,
# and a stub would let that shape drift out from under us unnoticed.
#
# No database is touched. PoolManager is a pure in-memory index that never calls
# into the pool_config values it stores, so opaque doubles suffice.
AR_REGISTRY_AVAILABLE = begin
  require('active_record')
  require('apartment/patches/connection_registry')
  true
rescue LoadError => e
  warn "[connection_registry_spec] Skipping: #{e.message}"
  false
end

RSpec.describe(Apartment::Patches::ConnectionRegistry) do
  before do
    skip('requires activerecord') unless AR_REGISTRY_AVAILABLE

    described_class.apply!
  end

  let(:pool_manager) { ActiveRecord::ConnectionAdapters::PoolManager.new }
  let(:seed_config) { double('seed pool_config') }
  let(:added_config) { double('added pool_config') }

  describe 'upstream shape (characterization)' do
    it 'is an unsynchronized nested Hash whose reads populate via a default proc' do
      # If either half of this stops holding, the patch is guarding the wrong
      # thing: the guarded method list and the snapshot in #each_pool_config
      # both exist because of this exact shape.
      expect(pool_manager.instance_variable_get(:@role_to_shard_mapping)).to(be_a(Hash))
      expect { pool_manager.get_pool_config(:no_such_role, :no_such_shard) }
        .to(change(pool_manager, :role_names).from([]).to([:no_such_role]))
    end

    it 'raises when a plain nested registry is written during iteration' do
      # The upstream failure this patch exists to prevent, reproduced on a bare
      # copy of AR's structure. MRI's iteration guard lives on the Hash object,
      # not on the thread, so the cross-thread and same-thread cases are one bug.
      registry = Hash.new { |hash, key| hash[key] = {} }
      registry[:writing][:seed] = seed_config

      expect do
        registry.each_value do |shards|
          shards.each_value { registry[:writing][:added] = added_config }
        end
      end.to(raise_error(RuntimeError, /during iteration/))
    end
  end

  describe 'shard registration during iteration' do
    before { pool_manager.set_pool_config(:writing, :seed, seed_config) }

    it 'does not raise' do
      expect do
        pool_manager.each_pool_config { pool_manager.set_pool_config(:writing, :added, added_config) }
      end.not_to(raise_error)
    end

    it 'registers the new shard' do
      pool_manager.each_pool_config { pool_manager.set_pool_config(:writing, :added, added_config) }

      expect(pool_manager.get_pool_config(:writing, :added)).to(be(added_config))
    end

    it 'yields the snapshot taken when iteration began' do
      yielded = []
      pool_manager.each_pool_config do |pool_config|
        yielded << pool_config
        pool_manager.set_pool_config(:writing, :added, added_config)
      end

      expect(yielded).to(eq([seed_config]))
    end
  end

  describe 'concurrent registration and iteration' do
    # Deterministic rather than a stress loop: the reader parks inside its
    # iteration block and only then does the mutation run. Unpatched, the reader
    # is still inside AR's Hash walk at that moment and an insert raises; patched,
    # the reader took its snapshot and released the lock before yielding, so the
    # mutation proceeds. A timing-based version of this passed against pristine
    # ActiveRecord — 500 inserts finish inside one scheduler slice, so the two
    # threads never overlapped.
    it 'lets another thread register a shard while an iteration is in progress' do
      pool_manager.set_pool_config(:writing, :seed, seed_config)

      outcome = with_iteration_parked { pool_manager.set_pool_config(:writing, :added, added_config) }

      expect(outcome[:finished]).to(be(true))
      expect(outcome[:error]).to(be_nil)
      expect(pool_manager.pool_configs(:writing)).to(contain_exactly(seed_config, added_config))
    end

    it 'lets another thread discard a shard while an iteration is in progress' do
      # The eviction half of the same race: Apartment's PoolReaper deregisters
      # from AR's handler on its timer thread while request threads are iterating.
      pool_manager.set_pool_config(:writing, :seed, seed_config)
      pool_manager.set_pool_config(:writing, :doomed, added_config)

      outcome = with_iteration_parked { pool_manager.remove_pool_config(:writing, :doomed) }

      expect(outcome[:finished]).to(be(true))
      expect(outcome[:error]).to(be_nil)
      expect(pool_manager.pool_configs(:writing)).to(contain_exactly(seed_config))
    end
  end

  describe 'mutual exclusion' do
    # Every registry accessor must acquire the shared monitor. An accessor left
    # unguarded is invisible until it is the one that races in production, so
    # each is asserted individually rather than trusting the module's shape.
    # :__config__ stands in for the pool_config double, which is not available
    # when this table is evaluated.
    {
      shard_names: [],
      role_names: [],
      pool_configs: [],
      each_pool_config: [],
      get_pool_config: %i[writing seed],
      set_pool_config: %i[writing seed __config__],
      remove_pool_config: %i[writing seed],
      remove_role: [:writing],
    }.each do |method_name, raw_args|
      it "serializes ##{method_name} on the shared registry monitor" do
        args = raw_args.map { |arg| arg == :__config__ ? seed_config : arg }

        parked = parks_while_registry_locked? do
          pool_manager.public_send(method_name, *args) { |_pool_config| nil }
        end

        expect(parked).to(be(true))
      end
    end

    it "serializes the connection handler's pool-manager upsert" do
      handler = ActiveRecord::ConnectionAdapters::ConnectionHandler.new

      parked = parks_while_registry_locked? { handler.send(:set_pool_manager, pool_manager_descriptor) }

      expect(parked).to(be(true))
    end
  end

  describe '.apply!' do
    it 'is idempotent' do
      applied_count = -> { ActiveRecord::ConnectionAdapters::PoolManager.ancestors.count(described_class::PoolManagerSync) }
      before_count = applied_count.call

      described_class.apply!

      expect(applied_count.call).to(eq(before_count))
    end

    it 'guards every public accessor upstream defines' do
      # A shape-drift canary. A method added upstream that this patch does not
      # guard is an unsynchronized hole; one removed upstream would make our
      # wrapper call a missing super.
      expect(described_class::POOL_MANAGER_METHODS)
        .to(match_array(ActiveRecord::ConnectionAdapters::PoolManager.instance_methods(false)))
    end

    it 'keeps the handler upsert private, as upstream declares it' do
      # A prepended method is public by default, so without an explicit `private`
      # this patch would widen a Rails internal into public API.
      handler_class = ActiveRecord::ConnectionAdapters::ConnectionHandler

      expect(handler_class.private_method_defined?(:set_pool_manager)).to(be(true))
      expect(handler_class.public_method_defined?(:set_pool_manager)).to(be(false))
    end

    describe 'upstream shape drift' do
      it 'raises rather than silently running unsynchronized when a method is gone' do
        drifted = Class.new # no registry accessors at all

        expect { serialize(drifted) }
          .to(raise_error(Apartment::ConfigurationError, /cannot serialize/))
        expect(drifted.ancestors).not_to(include(described_class::PoolManagerSync))
      end

      it 'accepts a method that merely moved to a superclass' do
        # super dispatches through the whole ancestor chain, so an upstream
        # refactor that relocates these methods is benign — and must not trip a
        # check that now raises.
        moved = Class.new(registry_shaped_class)

        expect { serialize(moved) }.not_to(raise_error)
        expect(moved.ancestors).to(include(described_class::PoolManagerSync))
      end

      it 'warns, but still patches, when upstream grows an accessor we do not guard' do
        grown = Class.new(registry_shaped_class) { def brand_new_accessor; end }
        allow(described_class).to(receive(:warn))

        serialize(grown, exhaustive: true)

        expect(described_class).to(have_received(:warn).with(/brand_new_accessor/))
        expect(grown.ancestors).to(include(described_class::PoolManagerSync))
      end
    end
  end

  def serialize(klass, exhaustive: false)
    described_class.send(:serialize!, klass, described_class::POOL_MANAGER_METHODS,
                         described_class::PoolManagerSync, exhaustive: exhaustive)
  end

  # A stand-in with the same accessor names as AR's PoolManager. Bodies are never
  # invoked — only their presence is under test.
  def registry_shaped_class
    Class.new do
      Apartment::Patches::ConnectionRegistry::POOL_MANAGER_METHODS.each do |name|
        define_method(name) { |*| nil }
      end
    end
  end

  # Runs +block+ in another thread while a reader thread is parked inside
  # +pool_manager.each_pool_config+. Returns whether the worker finished WHILE the
  # reader was still parked, plus anything it raised.
  #
  # That "while still parked" part is the whole assertion. An implementation that
  # held the monitor across the yield would leave the worker blocked; releasing
  # the reader afterwards would then let it finish cleanly, and an example that
  # only checked for the absence of an error would pass on the strength of a
  # five-second stall.
  def with_iteration_parked(&block)
    iterating = Queue.new
    release = Queue.new

    reader = Thread.new do
      parked = false
      pool_manager.each_pool_config do |_pool_config|
        next if parked

        parked = true
        iterating << :inside
        release.pop
      end
    end
    reader.report_on_exception = false
    raise('reader thread never entered the iteration') if iterating.pop(timeout: 5).nil?

    worker = Thread.new(&block)
    worker.report_on_exception = false
    finished = !worker.join(5).nil?
    error = worker_error(worker) if finished

    { finished: finished, error: error }
  ensure
    release << :go
    reader&.join(5)
  end

  def worker_error(worker)
    worker.value
    nil
  rescue StandardError => e
    e
  end

  # Blocked-on-a-lock threads report status 'sleep'; a thread that ran to
  # completion reports false. Polled rather than slept on a fixed interval so
  # the assertion is not a timing bet.
  def parks_while_registry_locked?(&block)
    parked = false
    worker = nil

    described_class::SYNC.synchronize do
      worker = Thread.new(&block)
      worker.report_on_exception = false
      parked = parked?(worker)
    end

    # Parking alone is not enough: a wrapper that acquired the monitor and then
    # hung or raised would satisfy the status check. The call has to complete,
    # and complete cleanly, once the monitor is free.
    raise('guarded call did not finish after the monitor was released') unless worker.join(5)

    worker.value
    parked
  end

  def parked?(thread)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5

    while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      case thread.status
      when 'sleep' then return true
      when false, nil then return false # ran to completion, or died
      end

      sleep(0.005)
    end

    false
  end

  # AR >= 8.0 keys the handler's manager cache by a ConnectionDescriptor; 7.2
  # keys it by the connection-name String. The patch never reads the argument,
  # but the spec has to pass something the real method accepts.
  def pool_manager_descriptor
    if defined?(ActiveRecord::ConnectionAdapters::ConnectionHandler::ConnectionDescriptor)
      ActiveRecord::ConnectionAdapters::ConnectionHandler::ConnectionDescriptor.new('ApartmentSpec')
    else
      'ApartmentSpec'
    end
  end
end
