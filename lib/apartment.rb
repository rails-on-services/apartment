# frozen_string_literal: true

require 'zeitwerk'
require 'active_support'
require 'active_support/current_attributes'
require 'concurrent'

# Set up Zeitwerk autoloader for the Apartment namespace.
# Must happen before requiring files that define constants in the Apartment module.
loader = Zeitwerk::Loader.for_gem(warn_on_extra_files: false)

# errors.rb defines multiple constants (not a single Errors class),
# so it must be loaded explicitly rather than autoloaded.
loader.ignore("#{__dir__}/apartment/errors.rb")

# Railtie is loaded explicitly via require_relative at the bottom of this file.
loader.ignore("#{__dir__}/apartment/railtie.rb")

# Rake tasks are loaded by the Railtie, not autoloaded.
loader.ignore("#{__dir__}/apartment/tasks")

# CLI is loaded explicitly (require 'apartment/cli') by rake tasks and the binstub.
# Ignoring cli.rb avoids Zeitwerk mapping it to Apartment::Cli (wrong casing).
# Ignoring cli/ avoids autoloading Thor subcommands before Thor is required.
loader.ignore("#{__dir__}/apartment/cli.rb")
loader.ignore("#{__dir__}/apartment/cli")

# RuboCop cops live under lib/rubocop and load only via RuboCop's `require:`
# (config), never through Apartment's autoloader. Ignore avoids Zeitwerk mapping
# lib/rubocop to a `Rubocop` constant (wrong casing vs RuboCop) — same rationale
# as the cli.rb / cli ignores above.
loader.ignore("#{__dir__}/rubocop")

# Rails generators live under lib/generators and are loaded on demand by Rails'
# generator machinery, never autoloaded. They follow Rails' generator naming
# (Apartment::InstallGenerator), not Zeitwerk's path-based inference
# (Generators::Apartment::Install::InstallGenerator), so leaving them managed
# makes `Zeitwerk::Loader.eager_load_all` — which Rails runs whenever a host app
# sets config.eager_load = true (production/CI) — raise Zeitwerk::NameError at
# boot. Ignoring the directory is the canonical for_gem pattern for gems that
# ship generators.
loader.ignore("#{__dir__}/generators")

# Collapse concerns/ so Zeitwerk maps lib/apartment/concerns/model.rb
# to Apartment::Model (not Apartment::Concerns::Model). Mirrors the
# Rails convention for app/models/concerns/.
loader.collapse("#{__dir__}/apartment/concerns")

loader.setup

require_relative 'apartment/errors'
require_relative 'apartment/tenant_validator'

module Apartment # rubocop:disable Metrics/ModuleLength
  class << self # rubocop:disable Metrics/ClassLength
    attr_reader :config, :pool_manager, :pool_reaper
    attr_writer :adapter

    # Fiber-local latch guarding the lazy build below. Thread#[] is fiber-local, so a
    # fiber-based server gets its own, and a nested build cannot see a sibling's.
    BUILDING_ADAPTER = :apartment_building_adapter

    # Lazy-loading adapter. Built on first access via build_adapter.
    # Can be set manually (e.g., in tests) via Apartment.adapter=.
    #
    # The latch is a backstop, not the fix. @adapter is not assigned until the build
    # returns, so anything inside the build that resolves a connection through the
    # tenant-aware pool lookup asks for the adapter again and recurses to
    # SystemStackError — a stack dump naming no cause a reader can act on.
    # default_connection_db_config closes the one such circle the gem had; this turns
    # any future one into a sentence.
    def adapter
      return @adapter if @adapter

      if Thread.current[BUILDING_ADAPTER]
        raise(ConfigurationError,
              'Apartment.adapter was re-entered while the adapter was still being ' \
              'built, which means something in the build resolved a connection ' \
              'through the tenant-aware pool lookup. Build the adapter before ' \
              'switching tenants — Apartment.adapter with no tenant current, or an ' \
              'explicit Apartment.adapter= — and report this, because the gem should ' \
              'not need you to.')
      end

      Thread.current[BUILDING_ADAPTER] = true
      begin
        @adapter ||= build_adapter
      ensure
        Thread.current[BUILDING_ADAPTER] = nil
      end
    end

    # An always-valid validator, used when config.tenant_validator is false.
    ALWAYS_VALID_TENANT = ->(_name) { true }

    # Guards lazy construction of the built-in validator. A constant (not an
    # ivar) so it survives clear_config, which nils @built_in_tenant_validator.
    BUILT_IN_VALIDATOR_MUTEX = Mutex.new

    # Resolves config.tenant_validator to a callable: false -> always valid,
    # nil -> the process's built-in TenantValidator (memoized), a callable ->
    # itself.
    def tenant_validator
      case (configured = @config&.tenant_validator)
      when false then ALWAYS_VALID_TENANT
      when nil then built_in_tenant_validator
      else configured
      end
    end

    # Registry of models that declared pin_tenant.
    # Uses Concurrent::Set for thread safety (Zeitwerk autoload in threaded servers).
    def pinned_models
      @pinned_models ||= Concurrent::Set.new
    end

    def register_pinned_model(klass)
      pinned_models.add(klass)
    end

    # Check if a class (or any of its ancestors) is a pinned model.
    # Delegates to the class's own apartment_pinned? (defined by the
    # Apartment::Model concern). Falls back to registry lookup for
    # models registered via the excluded_models shim without the concern.
    def pinned_model?(klass)
      if klass.respond_to?(:apartment_pinned?)
        klass.apartment_pinned?
      else
        klass.ancestors.any? { |a| a.is_a?(Class) && pinned_models.include?(a) }
      end
    end

    def activated?
      @activated == true
    end

    # Returns the current tenant list. Single resolver used by Tenant.each,
    # Migrator, SchemaCache, and the CLI commands. Honors the per-block
    # override set by Tenant.with_tenants_provider / with_tenants when present;
    # otherwise resolves through @config.tenants_provider.
    #
    # The override (or the configured provider) may itself be a callable, in
    # which case it is invoked on every access. Whatever the source, the
    # resolved value must respond to :each.
    def tenant_names
      raise(ConfigurationError, 'Apartment not configured. Call Apartment.configure first.') unless @config

      override = Current.tenant_override
      source = override || @config.tenants_provider
      result = source.respond_to?(:call) ? source.call : source

      unless result.respond_to?(:each)
        source_label = override ? 'tenant_override' : 'tenants_provider'
        raise(ConfigurationError,
              "#{source_label} must return an Enumerable, got #{result.class}")
      end
      result
    end

    # v3 compatibility: Apartment.excluded_models returns the excluded models list.
    # Deprecated in v4 (use Apartment::Model + pin_tenant instead).
    def excluded_models
      raise(ConfigurationError, 'Apartment not configured. Call Apartment.configure first.') unless @config

      @config.excluded_models
    end

    def process_pinned_model(klass)
      unless adapter
        warn "[Apartment] Cannot process pinned model #{klass.name || klass.inspect}: " \
             'adapter not initialized. Model registered but unprocessed.'
        return
      end
      adapter.process_pinned_model(klass)
    end

    # Configure Apartment v4. Yields a Config instance, validates it,
    # and prepares the module for use.
    #
    #   Apartment.configure do |config|
    #     config.tenant_strategy = :schema
    #     config.tenants_provider = -> { Tenant.pluck(:name) }
    #   end
    #
    def configure
      raise(ConfigurationError, 'Apartment.configure requires a block') unless block_given?

      new_config = Config.new
      yield(new_config)
      new_config.apply_defaults!
      new_config.validate!
      new_config.freeze!

      # Validation passed — tear down old state and swap in new.
      teardown_old_state
      @built_in_tenant_validator&.shutdown
      @built_in_tenant_validator = nil
      @config = new_config
      setup_pools!(new_config)
      @config
    end

    # Reset all configuration and stop background tasks.
    def clear_config
      teardown_old_state
      # Restore (un-qualify) pinned models, but keep them registered. pin_tenant
      # runs once when a model's class body loads and never re-runs, so the
      # registry is the only record of which models are pinned. Discarding it
      # would strand every pinned model unprocessed after the next configure.
      # The registry is bounded in production (pinned models are named
      # constants); a test process that pins anonymous classes accumulates them
      # here — acceptable, but count-sensitive specs must isolate it themselves.
      @pinned_models&.each { |klass| klass.apartment_restore! if klass.respond_to?(:apartment_restore!) }
      @built_in_tenant_validator&.shutdown
      @built_in_tenant_validator = nil
      @config = nil
      @pool_manager = nil
      @pool_reaper = nil
      @activated = false
    end

    # Activate the ActiveRecord patches pool-per-tenant depends on.
    # Idempotent — prepend on an already-prepended module is a no-op.
    #
    # ConnectionHandling routes AR::Base.connection_pool to the current tenant's
    # pool; ConnectionRegistry makes AR's own pool registry safe for the
    # concurrent shard registration that routing produces. The second is not
    # optional given the first: without it, a cold tenant switch can fail whenever
    # any thread happens to be iterating AR's pools — which Rails does through
    # ConnectionHandler#each_connection_pool at the start of every request or job
    # (ActiveRecord::QueryCache.run), at the end of every one
    # (ConnectionPool::ExecutorHooks.complete), and after writes
    # (clear_query_caches_for_current_thread). NOT from AR's ConnectionPool::Reaper,
    # which reads a private WeakRef list rather than the registry.
    def activate!
      require_relative('apartment/patches/connection_handling')
      require_relative('apartment/patches/connection_registry')
      ActiveRecord::Base.singleton_class.prepend(Patches::ConnectionHandling)
      Patches::ConnectionRegistry.apply!
      @activated = true
    end

    # Register a :tenant tag with ActiveRecord::QueryLogs so SQL queries
    # include a /* tenant='name' */ comment. No-op when sql_query_tags is
    # false or ActiveRecord::QueryLogs is not available.
    def activate_sql_query_tags!
      return unless @config&.sql_query_tags
      return unless defined?(ActiveRecord::QueryLogs)
      return if ActiveRecord::QueryLogs.tags.include?(:tenant)

      ActiveRecord::QueryLogs.taggings = ActiveRecord::QueryLogs.taggings.merge(
        tenant: -> { Apartment::Current.tenant }
      )
      ActiveRecord::QueryLogs.tags = ActiveRecord::QueryLogs.tags + [:tenant]
    end

    # Discard one tenant pool, whole: deregister its shard from AR's ConnectionHandler
    # and forget it in PoolManager, disconnecting it either way.
    # Safe to call when AR is not loaded or config is not set (no-op).
    # Used by PoolReaper eviction, AbstractAdapter#drop, and teardown.
    #
    # Both registries are updated because either one alone is wrong: deregistering
    # from AR while the manager still holds the pool wedges the tenant permanently
    # (the manager keeps handing back a pool AR has forgotten), and forgetting it in
    # the manager alone leaks the AR registration and a live backend when the tenant
    # is never re-accessed. Every internal caller already removes from the manager
    # first, so the removal here is a no-op for them.
    #
    # The pool is disconnected here rather than left to AR, which disconnects only a
    # pool it actually finds registered (ConnectionHandler#disconnect_pool_from_pool_manager
    # guards `pool_config.disconnect!` behind `if pool_config`). A manager-held pool
    # with no matching AR registration is reachable — the integration suite swaps the
    # ConnectionHandler per example — and since we have just removed it from the
    # manager, no later `PoolManager#clear` will disconnect it either. Mirrors
    # AbstractAdapter#drop, which already removes, disconnects, then deregisters.
    # (Callers that remove the pool from the manager THEMSELVES must disconnect it
    # themselves too — the removal here returns nil for them, so there is nothing left
    # for us to disconnect. PoolReaper#evict_tenant and Migrator#evict_migration_pools
    # do exactly that.)
    # See docs/designs/out-of-band-tenant-ddl.md.
    #
    # NOT SAFE inside a PoolManager create block — use +deregister_ar_shard+ there.
    # PoolManager's @pools is a Concurrent::Map whose MRI backend guards
    # +compute_if_absent+ and +delete+ with the SAME non-reentrant mutex, so removing
    # a pool from inside the create block raises ThreadError ("deadlock; recursive
    # locking"). The manager removal below is exactly that call.
    #
    # ORDER: AR first, manager removal in an +ensure+. The manager removal is an
    # in-memory delete that cannot meaningfully fail, so it is the step that may run
    # unconditionally; AR's removal does IO and is the one that can raise. Running the
    # fallible step first, with the infallible one guaranteed after, means the call
    # always ends with BOTH registries clear.
    #
    # Manager-first would be a race: between the manager delete and AR's removal, a
    # concurrent tenant switch misses the manager, calls establish_connection — which
    # RETURNS THE STILL-REGISTERED OLD POOL (ConnectionHandler#establish_connection
    # reuses a pool whose db_config is equal) — and stores that doomed pool back in
    # the manager. AR then unregisters and disconnects it, leaving the manager holding
    # a dead pool: the permanent wedge this method exists to prevent, reintroduced.
    # In this order the same interleaving costs at most one failed request, and the
    # ensure clears the manager so the next switch rebuilds cleanly.
    #
    # Deliberately un-rescued at this level: both steps rescue their own failures, and
    # swallowing everything here is what once hid a ThreadError, silently orphaning the
    # pool the caller asked us to discard. Misuse should be loud.
    # @api private
    # The PoolManager key for one tenant under one connection role. Pools are keyed by
    # both because a tenant migrated under an elevated role and served under the writing
    # role are different pools with different credentials. deregister_ar_shard parses the
    # role back off the tail, so the separator is part of the contract, not cosmetic.
    def pool_key(tenant, role)
      "#{tenant}:#{role}"
    end

    # @api private
    # True when at least one of +pool+'s connections is leased or holds an open
    # transaction (a long migration, a batch job, an unpinned fixture transaction).
    # Discarding such a pool orphans that work, so every caller that removes a pool
    # outside the reaper's own cycle checks this first. nil counts as not in use: an
    # untracked pool has nothing to orphan.
    def pool_in_use?(pool)
      return false unless pool.respond_to?(:connections)

      pool.connections.any? do |conn|
        (conn.respond_to?(:in_use?) && conn.in_use?) ||
          (conn.respond_to?(:open_transactions) && conn.open_transactions.positive?)
      end
    end

    def deregister_shard(pool_key)
      return unless @config && defined?(ActiveRecord::Base)

      begin
        deregister_ar_shard(pool_key)
      ensure
        disconnect_removed_pool(@pool_manager&.remove(pool_key), pool_key)
      end
    end

    # @api private
    # Disconnect a pool that has been removed from PoolManager. Idempotent with AR's
    # own disconnect on the happy path (ConnectionPool#disconnect! empties @connections,
    # so a second call has nothing left to close); load-bearing only when AR has no
    # matching registration to disconnect, in which case nothing else will close it.
    #
    # Public because the callers that remove a pool from the manager THEMSELVES — and
    # therefore get nil back from deregister_shard's own removal — must disconnect what
    # they removed: PoolReaper#evict_tenant, Migrator#evict_migration_pools,
    # AbstractAdapter#drop. Rescued so one broken pool cannot abort the caller.
    def disconnect_removed_pool(pool, pool_key)
      return unless pool.respond_to?(:disconnect!)

      pool.disconnect!
    rescue StandardError => e
      warn "[Apartment] Failed to disconnect pool for #{pool_key}: #{e.class}: #{e.message}"
    end

    # Deregister all tenant pools from AR's ConnectionHandler and clear the
    # pool manager cache. Pools rebuild lazily on the next +connection_pool+
    # call.
    #
    # Execution context (+Apartment::Current+: tenant, tenant_override, etc.)
    # is left untouched — pool lifecycle and tenant context are separate
    # concerns. A caller that also wants to drop tenant context resets it
    # explicitly via +Apartment::Tenant.reset+.
    #
    # Called automatically by +Apartment::TestFixtures+ before Rails' fixture
    # setup iterates shards. Can also be called manually in custom test
    # harnesses that cycle tenant pools between examples.
    #
    # @return [void]
    # @see Apartment::TestFixtures
    def reset_tenant_pools!
      guard_pinned_pools_during_fixtures!
      deregister_all_tenant_pools
      @pool_manager&.clear
    end

    private

    # The ActiveRecord half of a discard: deregister the shard (which disconnects the
    # pool AR holds), leaving PoolManager untouched. The ONLY form that is safe inside
    # a PoolManager create block — see the re-entrancy note on +deregister_shard+ —
    # and correct there anyway: compute_if_absent does not store the pool until the
    # block returns, so there is no manager entry to remove.
    #
    # PRIVATE ON PURPOSE. This is a half-operation, and a reachable half-operation is
    # the bug this whole seam exists to eliminate: called on its own, it leaves AR
    # without the pool while PoolManager keeps handing it out, wedging the tenant for
    # the life of the process. The one legitimate caller reaches it with +send+.
    def deregister_ar_shard(pool_key)
      return unless @config && defined?(ActiveRecord::Base)

      _, separator, role_str = pool_key.to_s.rpartition(':')
      role = separator.empty? || role_str.empty? ? ActiveRecord.writing_role : role_str.to_sym

      shard_key = :"#{@config.shard_key_prefix}_#{pool_key}"
      ActiveRecord::Base.connection_handler.remove_connection_pool(
        'ActiveRecord::Base',
        role: role,
        shard: shard_key
      )
    rescue StandardError => e
      warn "[Apartment] Failed to deregister AR pool for #{pool_key}: #{e.class}: #{e.message}"
    end

    # Double-checked locking: the common path (already built) skips the mutex;
    # concurrent first callers serialize so exactly one validator is built.
    # TenantValidator.new subscribes to ActiveSupport::Notifications, so a
    # discarded duplicate would leak its subscription.
    def built_in_tenant_validator
      @built_in_tenant_validator ||
        BUILT_IN_VALIDATOR_MUTEX.synchronize { @built_in_tenant_validator ||= TenantValidator.new }
    end

    # Build the pool manager + reaper for a freshly-validated config and start
    # the background reaper. When a pool budget is configured (max_tenant_pools
    # and/or max_tenant_connections, via Config#effective_pool_budget), wire the
    # reaper as the pool manager's admission controller so cold creates are
    # bounded synchronously; otherwise the manager keeps its lock-free create path.
    def setup_pools!(new_config)
      budget = new_config.effective_pool_budget
      @pool_manager = PoolManager.new
      @pool_reaper = PoolReaper.new(
        pool_manager: @pool_manager,
        interval: new_config.reaper_interval,
        idle_timeout: new_config.pool_idle_timeout,
        max_total: budget,
        default_tenant: new_config.default_tenant,
        shard_key_prefix: new_config.shard_key_prefix,
        overflow_policy: new_config.pool_overflow_policy
      )
      @pool_manager.admission_controller = @pool_reaper if budget
      @pool_reaper.start
    end

    # Safely tear down old state. Stops the reaper first (so it doesn't
    # evict mid-cleanup), then deregisters tenant pools from AR's
    # ConnectionHandler, then clears the pool manager.
    def teardown_old_state
      begin
        @pool_reaper&.stop
      rescue StandardError => e
        warn "[Apartment] PoolReaper.stop failed during teardown: #{e.class}: #{e.message}"
      end
      deregister_all_tenant_pools
      @pool_manager&.clear
      @adapter = nil
    end

    # Refuse to discard tenant pools while Rails' transactional fixtures own
    # them. The recreated pool would have a fresh object identity that the
    # fixture transaction never enrolled, causing silent test pollution.
    # Test-env-scoped via +Rails.env.test?+ so production keeps the existing
    # semantics; reuses the same +@pinned_connection+ primitive the reaper
    # already reads. See docs/designs/fixture-pool-lifecycle.md.
    def guard_pinned_pools_during_fixtures!
      return unless rails_test_env?
      return unless @pool_manager

      @pool_manager.each_pair do |tenant_key, pool|
        next unless Apartment::PoolReaper.pool_pinned?(pool)

        raise(Apartment::FixtureLifecycleViolation, tenant_key)
      end
    end

    def rails_test_env?
      return false unless defined?(Rails) && Rails.respond_to?(:env)

      env = Rails.env
      env.respond_to?(:test?) ? env.test? : env.to_s == 'test'
    end

    def deregister_all_tenant_pools
      return unless @pool_manager

      @pool_manager.stats[:tenants]&.each do |tenant_key|
        deregister_shard(tenant_key)
      end
    end

    # Factory: resolve the correct adapter class based on strategy and database adapter.
    def build_adapter
      raise(ConfigurationError, 'Apartment not configured. Call Apartment.configure first.') unless @config

      strategy = config.tenant_strategy
      db_adapter = detect_database_adapter

      klass = case strategy
              when :schema
                require_relative('apartment/adapters/postgresql_schema_adapter')
                Adapters::PostgresqlSchemaAdapter
              when :database_name
                case db_adapter
                when /postgresql/, /postgis/
                  require_relative('apartment/adapters/postgresql_database_adapter')
                  Adapters::PostgresqlDatabaseAdapter
                when /mysql2/
                  require_relative('apartment/adapters/mysql2_adapter')
                  Adapters::Mysql2Adapter
                when /trilogy/
                  require_relative('apartment/adapters/trilogy_adapter')
                  Adapters::TrilogyAdapter
                when /sqlite/
                  require_relative('apartment/adapters/sqlite3_adapter')
                  Adapters::Sqlite3Adapter
                else
                  raise(AdapterNotFound, "No adapter for database: #{db_adapter}")
                end
              else
                raise(AdapterNotFound, "Strategy #{strategy} not yet implemented")
              end

      klass.new(default_connection_db_config.configuration_hash)
    end

    def detect_database_adapter
      default_connection_db_config.adapter
    end

    # The DEFAULT connection's db_config, resolved with the tenant unset.
    #
    # Unsetting it is what breaks a circle, not a precaution: connection_db_config is
    # connection_pool.db_config, connection_pool goes through
    # Patches::ConnectionHandling, and that patch asks Apartment.adapter for
    # shared_pinned_connection?. Reading this under a live tenant therefore re-enters
    # the very build it is part of, and @adapter is not assigned until the build
    # returns, so it recursed until SystemStackError.
    #
    # The circle was reachable, not theoretical. configure clears @adapter and
    # activate! does not rebuild it, so any process whose FIRST Apartment operation is
    # a tenant switch — a job worker, a rake task, rails runner — took it. The request
    # path escaped by accident: Elevators::Generic resolves the adapter per request
    # before it switches, filling the memo while no tenant is current.
    #
    # The default connection is also the right answer. Which engine the app runs on is
    # a property of the app rather than of whichever tenant happens to be current, and
    # a tenant's config is derived from the default one anyway.
    def default_connection_db_config
      Apartment::Current.set(tenant: nil) do
        ActiveRecord::Base.connection_db_config
      end
    end
  end
end

# Prepend the sequence-name patch whenever the PostgreSQL adapter loads
# (immediately, if it already has). Registered at gem load rather than in
# activate! because ActiveRecord memoizes Model.sequence_name at first touch,
# which can happen during boot before Apartment.activate! runs. No-op for apps
# that never load the PostgreSQL adapter, so MySQL/SQLite consumers never pull
# in pg. See the patch file for the full rationale.
ActiveSupport.on_load(:active_record_postgresqladapter) do
  prepend(Apartment::Patches::PostgresqlSequenceName)
end

# Load Railtie when Rails is present (standard gem convention).
# Railtie is Zeitwerk-ignored — this explicit require is the only load path.
require_relative 'apartment/railtie' if defined?(Rails::Railtie)
