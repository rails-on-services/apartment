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
    # iteration block and only then does the writer register. Unpatched, the
    # reader is still inside AR's Hash walk at that moment and the writer's
    # insert raises; patched, the reader took its snapshot and released the lock
    # before yielding, so the writer proceeds. A timing-based version of this
    # passed against pristine ActiveRecord — 500 inserts finish inside one
    # scheduler slice, so the two threads never overlapped.
    it 'lets another thread register a shard while an iteration is in progress' do
      pool_manager.set_pool_config(:writing, :seed, seed_config)
      iterating = Queue.new
      release = Queue.new
      writer_error = nil

      reader = Thread.new do
        parked = false
        pool_manager.each_pool_config do |_pool_config|
          next if parked

          parked = true
          iterating << :inside
          release.pop
        end
      end
      iterating.pop

      writer = Thread.new do
        pool_manager.set_pool_config(:writing, :added, added_config)
      rescue StandardError => e
        writer_error = e
      end
      writer.join(5)

      release << :go
      reader.join(5)

      expect(writer_error).to(be_nil)
      expect(pool_manager.pool_configs(:writing)).to(contain_exactly(seed_config, added_config))
    end

    it 'lets another thread discard a shard while an iteration is in progress' do
      # The reaper thread's half of the same race: eviction deregisters from AR's
      # handler while request threads are iterating.
      pool_manager.set_pool_config(:writing, :seed, seed_config)
      pool_manager.set_pool_config(:writing, :doomed, added_config)
      iterating = Queue.new
      release = Queue.new
      remover_error = nil

      reader = Thread.new do
        parked = false
        pool_manager.each_pool_config do |_pool_config|
          next if parked

          parked = true
          iterating << :inside
          release.pop
        end
      end
      iterating.pop

      remover = Thread.new do
        pool_manager.remove_pool_config(:writing, :doomed)
      rescue StandardError => e
        remover_error = e
      end
      remover.join(5)

      release << :go
      reader.join(5)

      expect(remover_error).to(be_nil)
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

    it 'skips (and warns) when the upstream shape is unrecognized' do
      drifted = Class.new # no registry accessors at all
      allow(described_class).to(receive(:warn))

      described_class.send(:serialize!, drifted, described_class::POOL_MANAGER_METHODS,
                           described_class::PoolManagerSync)

      expect(drifted.ancestors).not_to(include(described_class::PoolManagerSync))
      expect(described_class).to(have_received(:warn).with(/unrecognized/))
    end
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

    worker&.join(5)
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
