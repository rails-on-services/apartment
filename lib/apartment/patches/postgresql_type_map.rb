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
    # Two public :nodoc: seams, identical on Rails 7.2 through main:
    #
    # * clear_cache!(new_connection: true) is Rails' own "the socket is being
    #   replaced, drop connection-derived caches" signal, called from reconnect!,
    #   disconnect! and reset!. We drop @type_map there, so every path to a new
    #   physical connection reaches reload_type_map with a nil map.
    # * reload_type_map with a nil map ADOPTS the shared instance (building and
    #   publishing it if this is the first connection to that database); with a
    #   live map it REBUILDS into a fresh instance and republishes. The live-map
    #   callers upstream are the enum DDL helpers only. A published map is
    #   never cleared in place: other holders keep resolving against it and pick
    #   up the rebuilt one on their next physical reconnect, learning any new
    #   OID lazily through get_oid_type meanwhile, exactly as a stale
    #   per-connection map does today.
    #
    # The build writes into this adapter's own @type_map before publishing
    # because initialize_type_map loads through the private +type_map+ reader,
    # not its argument (load_additional_types constructs
    # TypeMapInitializer.new(type_map)). That reader is the one private
    # dependency; apply! refuses to boot without it.
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
        # Forwards whatever it is given: 7.2 through 8.1 take an optional parent,
        # Rails main takes nothing, and the adapter passes nothing on either.
        def initialize(...)
          super
          @mapping = Concurrent::Map.new
        end
      end

      # [host, port, database, default_timezone] => SharedTypeMap. Timezone is
      # part of the key because initialize_type_map bakes @default_timezone into
      # the time and timestamp registrations.
      REGISTRY = Concurrent::Map.new

      PUBLIC_SEAMS = %i[reload_type_map clear_cache!].freeze
      PRIVATE_SEAMS = %i[initialize_type_map].freeze

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
        # A test hook for suites that need a cold start, not a configuration knob.
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

          if @type_map.nil?
            @type_map = REGISTRY[key] || apartment_publish_type_map(key)
          else
            REGISTRY[key] = apartment_build_type_map
          end
        end
      end

      private

      def apartment_type_map_key
        [@config[:host], @config[:port], @config[:database], @default_timezone]
      end

      # put_if_absent rather than compute_if_absent: the build runs catalog
      # queries on this connection, and no registry lock is held across that
      # I/O. A lost race costs one redundant build, which is today's cost once.
      def apartment_publish_type_map(key)
        built = apartment_build_type_map
        REGISTRY.put_if_absent(key, built) || built
      end

      def apartment_build_type_map
        @type_map = SharedTypeMap.new
        initialize_type_map
        @type_map
      end
    end
  end
end
