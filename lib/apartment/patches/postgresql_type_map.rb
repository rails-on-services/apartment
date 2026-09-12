# frozen_string_literal: true

# Referenced in a class body below. Rails requires it from the PostgreSQL
# adapter file, which an eager-loading host app may not have loaded yet.
require 'active_record/type/hash_lookup_type_map'

module Apartment
  module Patches
    # Shares one PostgreSQL OID type map per database across every adapter in
    # the process.
    #
    # Rails builds the type map per connection: configure_connection ends in
    # reload_type_map, which clears @type_map and runs initialize_type_map, and
    # that issues three pg_type queries (load_types_queries). Two of them have
    # no usable index and sequential-scan pg_type, which grows by two rows per
    # table per tenant schema. Pool-per-tenant pays that on every cold tenant
    # pool, so a nightly sweep over hundreds of tenants rebuilds the same map
    # hundreds of times against a catalog hundreds of times larger than a
    # single-schema app's. Measured at 65 ms per connect for 500 schemas of
    # 220 tables. The map is database-scoped (OIDs are), so one instance can
    # serve every tenant pool. Design: docs/designs/postgresql-type-map-sharing.md.
    #
    # Two public :nodoc: seams, identical on Rails 8.1 and main:
    #
    # * clear_cache!(new_connection: true) is Rails' own "the socket is being
    #   replaced, drop connection-derived caches" signal, called from reconnect!,
    #   disconnect! and reset!. We drop @type_map there, so every path to a new
    #   physical connection reaches reload_type_map with a nil map.
    # * reload_type_map with a nil map ADOPTS the shared instance (building and
    #   publishing it if this is the first connection to that database); with a
    #   live map it REBUILDS into a fresh instance and republishes. The live-map
    #   callers upstream are the enum DDL helpers and disable_extension. A
    #   published map is
    #   never cleared in place: other holders keep resolving against it and pick
    #   up the rebuilt one on their next physical reconnect, learning any new
    #   OID lazily through get_oid_type meanwhile, exactly as a stale
    #   per-connection map does today.
    #
    # The build writes into this adapter's own @type_map before publishing
    # because initialize_type_map loads through the private +type_map+ reader,
    # not its argument (load_additional_types constructs
    # TypeMapInitializer.new(type_map)). Both that reader and
    # initialize_type_map are checked by apply!, which refuses to boot without
    # either.
    #
    # RETENTION, measured rather than bounded. An entry is removed only when a
    # later publish supersedes it (see #apartment_supersede_stale_identities),
    # so a process retains one map per database it has connected to, times the
    # timezone variants live against it. One built map
    # holds ~138 registrations and 88.5 KB of RSS (measured against PostgreSQL
    # 18 on Rails 8.1). Schema-per-tenant -- the common case, and the one this
    # patch was written for -- has exactly ONE key for the whole process. Only
    # database-per-tenant grows, and it grows with the tenants a process
    # actually serves rather than with time: 570 tenant databases is ~49 MB. No
    # eviction policy ships because a cap tight enough to bound that
    # meaningfully is also tight enough to thrash the nightly sweep it exists to
    # speed up, which is the deployment that has the problem in the first place.
    # Eviction is semantically free if that ever changes -- dropping an entry
    # only costs the next cold connection one rebuild, which is the unpatched
    # behaviour -- so a bound can land later with no correctness migration.
    # +reset!+ is the escape hatch in the meantime.
    module PostgresqlTypeMap
      # HashLookupTypeMap whose mapping is a Concurrent::Map.
      #
      # Upstream keeps @mapping in a plain Hash because one connection owns it.
      # Shared, it sees lock-free reads from every thread and occasional writes
      # from lazy OID registration. On MRI a plain Hash would already be safe
      # here (single C calls, no Ruby-level iteration in this class, Integer and
      # String keys), but the argument should not be implicit: Concurrent::Map
      # is the primitive Rails already uses for the other half of this object,
      # and every operation the adapter and TypeMapInitializer perform on the
      # store ([]=, fetch(key, default), key?, keys, clear) exists on it with the
      # same semantics.
      class SharedTypeMap < ActiveRecord::Type::HashLookupTypeMap
        # Forwards whatever it is given: 8.1 takes an optional parent, Rails main
        # takes nothing, and the adapter passes nothing on either. The forwarding is
        # what spans the two SUPPORTED lanes -- not a shim for a dropped Rails.
        def initialize(...)
          super
          @mapping = Concurrent::Map.new
        end
      end

      # [[host, port, database], [database_oid, postmaster_start_time],
      # default_timezone] => SharedTypeMap. Nested so the endpoint and the
      # catalog incarnation stay separable: #apartment_supersede_stale_identities
      # needs exactly that distinction. Everything but the timezone is read off
      # the live connection rather than @config -- see #apartment_type_map_key.
      # Timezone is part of the key because initialize_type_map bakes
      # @default_timezone into the time and timestamp registrations (verified on
      # 8.1 and main).
      REGISTRY = Concurrent::Map.new

      # Identity of the catalog behind the endpoint name, in one round trip.
      #
      # The database OID alone is NOT enough, which a probe settles rather than
      # an argument: template1, template0 and postgres hold OIDs 1, 4 and 5 on
      # every cluster ever initdb'd, so an app whose database is `postgres` --
      # the RDS default -- would have an identity check that evaluates to a
      # constant. Freshly provisioned clusters also hand the first user database
      # the same OID, 16384, so identical provisioning collides too. Neither
      # needs a pooler or any exotic topology; a plain endpoint swap is enough.
      # pg_postmaster_start_time() closes both: two live clusters disagree on it
      # with near-certainty.
      #
      # Both are world-readable and need no privilege, unlike
      # pg_control_system() and pg_control_checkpoint(), which are superuser-only
      # by default. Everything is schema-qualified because an unqualified name
      # can resolve to a temporary relation or an earlier entry in search_path.
      # Measured at 0.049 ms of execution, 0.096 ms including the round trip,
      # against 1.9 ms for a full type-map load on a 647-row pg_type and ~24 ms
      # on a 281,927-row one.
      # EXTRACT(EPOCH FROM ...) rather than the timestamptz itself, because the
      # value is read as text and a timestamptz renders through the session's
      # TimeZone and DateStyle. Two connection classes to the SAME catalog that
      # differ in those (a per-role `ALTER ROLE ... SET TimeZone` with no
      # explicit `variables` entry, say) would produce different identity
      # strings, split the key, and set the supersede rule below ping-ponging --
      # sharing quietly switching itself off, with no wrong data and no warning
      # to explain it. A numeric epoch depends on neither GUC.
      DATABASE_IDENTITY_SQL = <<~SQL.squish
        SELECT d.oid, EXTRACT(EPOCH FROM pg_catalog.pg_postmaster_start_time())
        FROM pg_catalog.pg_database d
        WHERE d.datname = pg_catalog.current_database()
      SQL

      PUBLIC_SEAMS = %i[reload_type_map clear_cache!].freeze
      PRIVATE_SEAMS = %i[initialize_type_map type_map].freeze

      class << self
        # FAILS CLOSED on a shape we cannot patch, for the same reason
        # ConnectionRegistry does: the failure this patch prevents is database
        # saturation during the nightly sweep, which is far harder to attribute
        # than a boot error naming the ActiveRecord version. Resolution uses
        # method_defined? so a seam that merely moved to a superclass still
        # counts. Prepend is idempotent, so apply! may run more than once.
        def apply!(adapter_class)
          missing = PUBLIC_SEAMS.reject { |name| adapter_class.method_defined?(name) } +
                    PRIVATE_SEAMS.reject { |name| adapter_class.private_method_defined?(name) }

          unless missing.empty?
            raise(Apartment::ConfigurationError,
                  'Apartment cannot share the PostgreSQL type map on ActiveRecord ' \
                  "#{ActiveRecord::VERSION::STRING}: expected method(s) #{missing.join(', ')} " \
                  'are gone. Without them every cold tenant pool reloads the OID type map ' \
                  'from pg_type. Upgrade ros-apartment to a version that supports this ' \
                  'ActiveRecord release.')
          end

          adapter_class.prepend(self)
          nil
        end

        # Forget every shared map. The next connection to each database rebuilds.
        # A test hook for suites that need a cold start, and the escape hatch for
        # an adopter who wants the retention described above reclaimed. Not a
        # configuration knob.
        def reset!
          REGISTRY.clear
        end
      end

      def clear_cache!(new_connection: false)
        super
        @type_map = nil if new_connection
      end

      def reload_type_map
        @lock.synchronize do
          key = apartment_type_map_key

          # No identity we can trust, so fall back to upstream's per-connection
          # map: sharing under an identity we could not confirm is the one thing
          # this must never do. Detaching first is load-bearing rather than
          # tidy -- upstream's reload_type_map CLEARS a live @type_map in place,
          # and if this adapter had already adopted the shared instance that
          # would blank the map every other holder is resolving against, which
          # is the invariant the whole design rests on.
          if key.nil?
            @type_map = nil
            return super
          end

          if @type_map.nil?
            @type_map = REGISTRY[key] || apartment_publish_type_map(key)
          else
            REGISTRY[key] = apartment_build_type_map
          end
        end
      end

      private

      # Ask the live connection, never @config, and ask the server which catalog
      # it actually is.
      #
      # Two different failures make @config alone the wrong source. First, libpq
      # fills in defaults the configuration hash cannot show -- dbname
      # defaulting to the user name, a service file, PGHOST/PGPORT/PGDATABASE,
      # hostaddr given without host -- so two adapters whose configs look
      # identical can land on different databases. PQhost, PQport and PQdb are
      # client-side reads of the RESOLVED parameters (measured ~0.06 us each)
      # and close all of that; PQhost reports hostaddr when only hostaddr was
      # given.
      #
      # Second, and the reason for the query: a name is not a catalog. This
      # patch deliberately survives +clear_cache!(new_connection: true)+, which
      # is Rails' "the socket is being replaced, drop what you cached" signal,
      # and that signal is exactly what heals a replaced catalog today. Put a
      # different cluster behind an unchanged endpoint -- an RDS blue/green
      # cutover on logical replication, a restore into the same name -- and
      # every connection drops, every adapter reconnects, and without this each
      # one would adopt the old catalog's map. Type OIDs in a fresh catalog
      # restart at 16384, so a stale registration does not merely go unused: it
      # can describe a DIFFERENT type that now holds its OID, and an enum gets
      # cast as a domain with nothing raised. (A promoted physical replica is
      # not affected either way -- its catalog is byte-identical, so the OIDs
      # still agree.) Within one cluster the OID counter is global and
      # monotonic, verified by probe, so a same-cluster drop and recreate leaves
      # dead entries rather than wrong ones; it is the cross-cluster case this
      # closes.
      #
      # The identity read runs on the raw connection rather than through the
      # adapter: it must not recurse into the type map it is about to resolve,
      # and PQexec's arity does not drift across the Rails versions this gem
      # supports. Any PG error means we could not establish identity, so we do
      # not share.
      #
      # A pooler whose single alias fans out across several databases, or across
      # clusters, IS caught: every resolved libpq parameter names the pooler, but
      # the identity query travels to the backend. What no connect-time check of
      # any kind can see is a pooler that moves a live client connection onto a
      # different cluster without configure_connection running again.
      def apartment_type_map_key
        raw = @raw_connection
        return nil unless raw

        [[raw.host, raw.port, raw.db], apartment_database_identity(raw), @default_timezone]
      rescue PG::Error => e
        # Sharing silently switching itself off has no symptom beyond "the
        # nightly got slow again", so leave evidence. Rescuing rather than
        # raising keeps a probe failure from breaking a connection that is
        # otherwise fine; the cost is one rebuilt map.
        warn('[Apartment] could not identify the database for type-map sharing ' \
             "(#{e.class}: #{e.message.lines.first&.strip}); this connection builds its own map.")
        nil
      end

      # Block form so the PG::Result is freed at once instead of waiting for GC.
      def apartment_database_identity(raw)
        raw.exec(DATABASE_IDENTITY_SQL) { |result| [result.getvalue(0, 0), result.getvalue(0, 1)] }
      end

      # put_if_absent rather than compute_if_absent: the build runs catalog
      # queries on this connection, and no registry lock is held across that
      # I/O. A lost race costs one redundant build, which is today's cost once.
      # Returning the WINNER is load-bearing -- the loser adopts it and drops its
      # own build, so every adapter converges on one instance.
      def apartment_publish_type_map(key)
        built = apartment_build_type_map
        published = REGISTRY.put_if_absent(key, built) || built
        apartment_supersede_stale_identities(key)
        published
      end

      # Drop entries for the same endpoint under a DIFFERENT catalog incarnation.
      #
      # Without this, putting the postmaster's start time in the key would trade
      # one unbounded growth for another: every database restart would strand an
      # entry per database, forever, which is growth in TIME rather than in
      # tenants. A superseded entry can never be adopted again -- its identity
      # will not recur -- so removing it costs nothing, and the worst case if an
      # endpoint is flipped back is one rebuild, which is the unpatched
      # behaviour. Timezone variants of the same live catalog share an endpoint
      # AND an identity, so they survive; only the identity slice discriminates.
      #
      # Keys are collected before deleting rather than deleted mid-iteration.
      #
      # Two publishers for the same endpoint under DIFFERENT identities can each
      # delete the other's entry, leaving the registry empty for that endpoint.
      # Harmless, and deliberately uncoordinated: it takes both incarnations
      # reachable at once (a cutover window), every live adapter holds its map by
      # reference, adoption is keyed by the identity the adopting connection
      # measured on its own socket, and losing costs one rebuild -- the unpatched
      # behaviour. Superseding before the publish has the symmetric race, so
      # there is nothing to buy.
      def apartment_supersede_stale_identities(key)
        endpoint, identity = key
        stale = REGISTRY.keys.select { |other| other[0] == endpoint && other[1] != identity }
        stale.each { |other| REGISTRY.delete(other) }
      end

      def apartment_build_type_map
        @type_map = SharedTypeMap.new
        # Parity with upstream's own reload, which clears this before
        # reinitialising. It exists only on Rails main, where it records whether
        # this adapter has run the deferred bulk pg_type query; the assignment is
        # inert on 8.1, where nothing reads it. Without it a rebuilt
        # map would skip the bulk half of the next deferred load -- still
        # correct, since the specific OID is always requested, but less than
        # upstream promises.
        @type_map_queried = false
        initialize_type_map
        @type_map
      end
    end
  end
end
