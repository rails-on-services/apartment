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

# Stands in for PG::Connection: the accessors the patch reads for the endpoint
# (PQhost / PQport / PQdb) plus the catalog-identity query it runs to tell one
# catalog from another behind the same name.
class FakeRawConnection
  Result = Struct.new(:columns) do
    def getvalue(_row, col) = columns[col]
  end

  attr_reader :host, :port, :db

  def initialize(host:, port:, db:, database_oid:, started_at: '2026-09-11 00:00:00')
    @host = host
    @port = port
    @db = db
    @identity = [database_oid, started_at]
  end

  # Block form, because that is how the patch calls it.
  def exec(sql)
    raise(ArgumentError, "unexpected identity SQL: #{sql}") unless sql.include?('pg_database')
    raise(@raise_with) if @raise_with

    result = Result.new(@identity)
    block_given? ? yield(result) : result
  end

  def raise_on_identity!(error) = @raise_with = error
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

        attr_reader :type_map

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

    # type_map is in this list because the build depends on it: upstream's
    # initialize_type_map loads through the reader, not through its argument, so
    # a rename would leave apartment_build_type_map publishing an empty map.
    %i[reload_type_map clear_cache! initialize_type_map type_map].each do |seam|
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

        # The key is read off the live connection rather than @config, so the
        # fake carries one.
        def initialize(database:, timezone: :utc, host: 'db.internal', database_oid: '16384',
                       started_at: '2026-09-11 00:00:00')
          @raw_connection = FakeRawConnection.new(
            host: host, port: 5432, db: database, database_oid: database_oid, started_at: started_at
          )
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

        attr_reader :raw_connection

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

    def connect(database: 'app', timezone: :utc, host: 'db.internal', database_oid: '16384',
                started_at: '2026-09-11 00:00:00')
      adapter_class
        .new(database: database, timezone: timezone, host: host, database_oid: database_oid,
             started_at: started_at)
        .tap(&:reload_type_map)
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

    it 'keys by the database the connection reached, since OIDs are database-wide, never by tenant' do
      # The database name here comes off the live connection, not @config. Two
      # configs that look identical can still land on different databases
      # through libpq defaulting (dbname from the user name, a service file,
      # PGDATABASE), so a difference visible ONLY on the connection has to split
      # the key -- which is what this fake varies.
      app = connect(database: 'app')
      other = connect(database: 'other')

      expect(other.loads).to(eq(1))
      expect(other.current_type_map).not_to(be(app.current_type_map))
    end

    it 'keys by host, so the same database name on two clusters is not shared' do
      primary = connect(host: 'primary.internal')
      secondary = connect(host: 'other-cluster.internal')

      expect(secondary.loads).to(eq(1))
      expect(secondary.current_type_map).not_to(be(primary.current_type_map))
    end

    it 'never shares when it cannot identify the database, falling back to upstream' do
      # Unreachable on every path Rails takes, but sharing under an identity we
      # could not confirm is the one failure this patch must not have.
      adapter = adapter_class.new(database: 'app')
      adapter.instance_variable_set(:@raw_connection, nil)

      adapter.reload_type_map

      expect(adapter.loads).to(eq(1))
      expect(adapter.current_type_map).not_to(be_a(described_class::SharedTypeMap))
      expect(described_class::REGISTRY).to(be_empty)
    end

    it 'refuses to adopt across a replaced catalog behind an unchanged endpoint name' do
      # The regression this closes. Because the patch deliberately survives
      # clear_cache!(new_connection: true), a reconnect no longer heals a
      # catalog that was swapped out from under the endpoint name -- an RDS
      # blue/green cutover on logical replication, or a restore into the same
      # name. A fresh catalog restarts type OIDs at 16384, so the stale
      # registrations do not go unused: they describe types that no longer hold
      # those OIDs. Identity has to come from the catalog, not the name.
      before_cutover = connect(database_oid: '16384')
      after_cutover = connect(database_oid: '99999')

      expect(after_cutover.loads).to(eq(1))
      expect(after_cutover.current_type_map).not_to(be(before_cutover.current_type_map))
    end

    it 'still refuses when the replacement cluster reuses the database OID' do
      # Why the OID alone is not identity, and this is the common shape rather
      # than the exotic one: template1, template0 and postgres hold OIDs 1, 4
      # and 5 on every cluster ever initdb'd, and identical provisioning gives
      # the first user database 16384 on both sides. Only the postmaster start
      # time separates two live clusters here.
      before_cutover = connect(database_oid: '5', started_at: '2026-01-01 00:00:00')
      after_cutover = connect(database_oid: '5', started_at: '2026-09-11 12:00:00')

      expect(after_cutover.loads).to(eq(1))
      expect(after_cutover.current_type_map).not_to(be(before_cutover.current_type_map))
    end

    it 'supersedes the superseded entry, so restarts do not accumulate maps forever' do
      # Putting the start time in the key would otherwise trade growth in
      # tenants for growth in TIME: one stranded entry per database per restart.
      connect(started_at: '2026-01-01 00:00:00')
      connect(started_at: '2026-09-11 12:00:00')

      expect(described_class::REGISTRY.size).to(eq(1))
    end

    it 'keeps timezone variants of one live catalog, which share an endpoint and an identity' do
      utc = connect(timezone: :utc)
      local = connect(timezone: :local)

      expect(described_class::REGISTRY.size).to(eq(2))
      expect(local.current_type_map).not_to(be(utc.current_type_map))
    end

    it 'detaches before falling back, so a probe failure cannot clear a map others hold' do
      # Upstream's reload_type_map CLEARS a live @type_map in place. An adapter
      # that had already adopted the shared instance and then lost its identity
      # probe would blank the map every other holder is resolving against.
      #
      # Both adapters ADOPT the map the ordinary way rather than having it
      # assigned, so the example exercises the real path: two healthy holders,
      # then one of them loses its probe mid-life (its connection drops after a
      # successful enum DDL, say) and reloads with the shared instance attached.
      holder = connect
      failing = connect
      shared = holder.current_type_map

      expect(failing.current_type_map).to(be(shared))
      failing.raw_connection.raise_on_identity!(PG::Error.new('probe failed'))
      # It warns rather than raising: a probe failure should not break a
      # connection that is otherwise fine, but sharing quietly switching itself
      # off has no symptom beyond a slow nightly, so it must leave evidence.
      expect { failing.reload_type_map }.to(output(/could not identify the database/).to_stderr)

      expect(shared.key?(23)).to(be(true))
      expect(failing.current_type_map).not_to(be(shared))
      expect(holder.current_type_map).to(be(shared))
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
      # One key, whichever build won the publish race.
      expect(described_class::REGISTRY.size).to(eq(1))
      expect(adapters.map(&:current_type_map).first).to(be(described_class::REGISTRY.values.first))
    end
  end
end
