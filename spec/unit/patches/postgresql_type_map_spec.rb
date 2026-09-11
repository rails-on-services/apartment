# frozen_string_literal: true

require 'spec_helper'

# The patch's contract with ActiveRecord is two public :nodoc: methods
# (reload_type_map, clear_cache!) and one private reader (type_map) that
# initialize_type_map loads through. A fake adapter reproducing upstream's
# reload_type_map shape exercises every branch without a database; the real
# HashLookupTypeMap is used for the SharedTypeMap examples because the one
# internal dependency (the @mapping ivar) is exactly what those examples guard.
#
# Requires real ActiveRecord + pg. Skips gracefully otherwise; PG_UNIT_REQUIRED=1
# turns the skip into a hard failure in the job that IS supposed to load pg.
PG_TYPE_MAP_AVAILABLE = begin
  require('active_record')
  require('active_record/connection_adapters/postgresql_adapter')
  require('apartment/patches/postgresql_type_map')
  true
rescue LoadError => e
  raise if ENV['PG_UNIT_REQUIRED']

  warn "[postgresql_type_map_spec] Skipping: #{e.message}"
  false
end

RSpec.describe(Apartment::Patches::PostgresqlTypeMap) do
  before do
    skip('requires the pg gem (run via a postgresql appraisal)') unless PG_TYPE_MAP_AVAILABLE

    described_class.reset!
  end

  after { described_class.reset! if PG_TYPE_MAP_AVAILABLE }

  describe 'SharedTypeMap' do
    let(:map) { described_class::SharedTypeMap.new }
    let(:integer) { ActiveRecord::Type::Integer.new }

    # If HashLookupTypeMap stops storing in @mapping, register_type lands in a
    # Hash this subclass does not own and every assertion below fails at once.
    it 'keeps its mapping in a Concurrent::Map, so lazy OID registration is safe across threads' do
      map.register_type(23, integer)

      expect(map.instance_variable_get(:@mapping)).to(be_a(Concurrent::Map))
      expect(map.instance_variable_get(:@mapping).key?(23)).to(be(true))
    end

    it 'round-trips the surface the adapter and TypeMapInitializer use' do
      map.register_type(23, integer)
      map.alias_type(1007, 23)

      expect(map.key?(23)).to(be(true))
      expect(map.keys).to(contain_exactly(23, 1007))
      expect(map.fetch(23)).to(eq(integer))
      expect(map.fetch(1007)).to(eq(integer))
      expect(map.lookup(99_999)).to(eq(ActiveRecord::Type.default_value))
      # A different OID: fetch memoizes per key, so the lookup above already cached 99_999.
      expect(map.fetch(88_888) { |oid| "missing #{oid}" }).to(eq('missing 88888'))

      map.clear
      expect(map.key?(23)).to(be(false))
    end
  end

  describe '.apply!' do
    def adapter_class_missing(*names)
      klass = Class.new do
        def reload_type_map; end
        def clear_cache!(new_connection: false); end

        private

        def initialize_type_map(_store = nil); end
      end
      names.each { |name| klass.send(:remove_method, name) }
      klass
    end

    it 'prepends onto a class with the expected seams, once' do
      klass = adapter_class_missing
      described_class.apply!(klass)
      described_class.apply!(klass)

      expect(klass.ancestors.count(described_class)).to(eq(1))
      expect(klass.ancestors.first).to(be(described_class))
    end

    %i[reload_type_map clear_cache! initialize_type_map].each do |seam|
      it "fails closed when #{seam} is gone" do
        expect { described_class.apply!(adapter_class_missing(seam)) }
          .to(raise_error(Apartment::ConfigurationError, /#{seam}/))
      end
    end
  end

  describe 'sharing' do
    # Upstream PostgreSQLAdapter#reload_type_map, verbatim in shape: under @lock,
    # clear the map if present or allocate one, then initialize_type_map, which
    # loads through the private type_map reader rather than its argument.
    let(:adapter_class) do
      klass = Class.new do
        attr_reader :loads

        def initialize(database:, timezone: :utc)
          @config = { host: 'db.internal', port: 5432, database: database }
          @default_timezone = timezone
          @lock = Monitor.new
          @type_map = nil
          @loads = 0
        end

        def clear_cache!(new_connection: false); end

        def reload_type_map
          @lock.synchronize do
            if @type_map
              type_map.clear
            else
              @type_map = ActiveRecord::Type::HashLookupTypeMap.new
            end

            initialize_type_map
          end
        end

        def current_type_map = @type_map

        private

        attr_reader :type_map

        def initialize_type_map(store = type_map)
          @loads += 1
          store.register_type(23, ActiveRecord::Type::Integer.new)
        end
      end
      described_class.apply!(klass)
      klass
    end

    def connect(database: 'app', timezone: :utc)
      adapter_class.new(database: database, timezone: timezone).tap(&:reload_type_map)
    end

    it 'loads the catalog once per database and hands every later adapter the same map' do
      first = connect
      second = connect

      expect(first.loads).to(eq(1))
      expect(second.loads).to(eq(0))
      expect(second.current_type_map).to(be(first.current_type_map))
      expect(first.current_type_map).to(be_a(described_class::SharedTypeMap))
      expect(first.current_type_map.key?(23)).to(be(true))
    end

    it 'keys the shared map by database, since OIDs are database-wide, never by tenant' do
      app = connect(database: 'app')
      other = connect(database: 'other')

      expect(other.loads).to(eq(1))
      expect(other.current_type_map).not_to(be(app.current_type_map))
    end

    it 'keys by default_timezone too, because initialize_type_map bakes it into the registrations' do
      utc = connect(timezone: :utc)
      local = connect(timezone: :local)

      expect(local.loads).to(eq(1))
      expect(local.current_type_map).not_to(be(utc.current_type_map))
    end

    it 'adopts the shared map on a new physical connection instead of rebuilding' do
      first = connect
      second = connect

      second.clear_cache!(new_connection: true)
      second.reload_type_map

      expect(second.loads).to(eq(0))
      expect(second.current_type_map).to(be(first.current_type_map))
    end

    it 'leaves the map in place when clear_cache! is not for a new connection' do
      adapter = connect
      before = adapter.current_type_map

      adapter.clear_cache!

      expect(adapter.current_type_map).to(be(before))
    end

    # The only live-map callers upstream are the enum DDL helpers. A published map
    # is never cleared in place: holders keep resolving against the old instance
    # and adopt the rebuilt one on their next physical reconnect.
    it 'rebuilds and republishes on an explicit reload, without clearing the map others hold' do
      first = connect
      second = connect
      original = first.current_type_map

      first.reload_type_map

      expect(first.loads).to(eq(2))
      expect(first.current_type_map).not_to(be(original))
      expect(original.key?(23)).to(be(true))
      expect(second.current_type_map).to(be(original))

      second.clear_cache!(new_connection: true)
      second.reload_type_map
      expect(second.loads).to(eq(0))
      expect(second.current_type_map).to(be(first.current_type_map))
    end

    it 'forgets every shared map on reset!, so the next connection rebuilds' do
      first = connect
      described_class.reset!
      second = connect

      expect(second.loads).to(eq(1))
      expect(second.current_type_map).not_to(be(first.current_type_map))
    end

    it 'converges concurrent first connections on one instance' do
      adapters = Array.new(8) { adapter_class.new(database: 'app') }
      barrier = Concurrent::CyclicBarrier.new(adapters.size)

      adapters.map do |adapter|
        Thread.new do
          barrier.wait
          adapter.reload_type_map
        end
      end.each(&:join)

      expect(adapters.map(&:current_type_map).uniq.size).to(eq(1))
      expect(adapters.sum(&:loads)).to(be >= 1)
    end
  end
end
