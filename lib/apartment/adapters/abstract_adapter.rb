# frozen_string_literal: true

require 'active_support/callbacks'
require 'active_support/core_ext/string/inflections'
require_relative '../tenant_name_validator'

module Apartment
  module Adapters
    class AbstractAdapter # rubocop:disable Metrics/ClassLength
      include ActiveSupport::Callbacks

      define_callbacks :create, :switch

      # The raw database connection configuration hash (from ActiveRecord).
      # Not to be confused with Apartment.config (the Apartment::Config object).
      attr_reader :connection_config

      def initialize(connection_config)
        @connection_config = connection_config
      end

      # Template method: validates tenant name then delegates to resolve_connection_config.
      # Called by ConnectionHandling — subclasses should NOT override this.
      # base_config_override: when supplied (e.g. a role-specific config from ConnectionHandling),
      # the adapter builds the tenant config on top of it instead of its own base_config.
      #
      # This validates only the PHYSICAL identifier (engine rules). Raw pool-key
      # safety (colon/whitespace/NUL that would corrupt "tenant:role") is enforced
      # by the sole production caller, ConnectionHandling#connection_pool, before
      # it builds the pool key — and independently by #create. A future caller
      # that invokes this directly, bypassing connection_pool, must validate the
      # raw tenant itself (TenantNameValidator.validate_common!).
      def validated_connection_config(tenant, base_config_override: nil)
        effective_base = base_config_override || base_config
        TenantNameValidator.validate!(
          physical_tenant_name(tenant),
          strategy: Apartment.config.tenant_strategy,
          adapter_name: effective_base['adapter']
        )
        config = resolve_connection_config(tenant, base_config: effective_base)
        apply_tenant_pool_size(config)
      end

      # Resolve a tenant-specific connection config hash.
      # Subclasses override to set strategy-specific keys.
      def resolve_connection_config(tenant, base_config: nil)
        raise(NotImplementedError)
      end

      # Create a new tenant (schema or database).
      # Validates the physical identifier create_tenant actually addresses
      # (raw schema name for :schema, environmentified database name otherwise),
      # so create and the pool-resolution path validate the same name.
      def create(tenant)
        validate_pool_key_safety!(tenant)
        TenantNameValidator.validate!(
          physical_tenant_name(tenant),
          strategy: Apartment.config.tenant_strategy,
          adapter_name: base_config['adapter']
        )
        suppressing_pending_migration_check do
          run_callbacks(:create) do
            run_tenant_ddl(tenant)
            seed(tenant) if Apartment.config.seed_after_create
            Instrumentation.instrument(:create, tenant: tenant)
          end
        end
      end

      # Drop a tenant.
      def drop(tenant)
        # Wrapped for the same reason create is: the container is owned by ddl_role,
        # and DROP SCHEMA requires ownership, so the writing role generally cannot drop
        # what the gem created. Only the engine call — the pool removal and shard
        # deregistration below are local bookkeeping and need no role.
        MigrationRole.wrap { drop_tenant(tenant) }
        removed_pools = Apartment.pool_manager&.remove_tenant(tenant) || []
        removed_pools.each do |pool_key, pool|
          # remove_tenant already took these out of the manager, so deregister_shard's
          # own removal returns nil and cannot disconnect them — we close them here.
          Apartment.disconnect_removed_pool(pool, pool_key)
          begin
            deregister_shard_from_ar_handler(pool_key)
          rescue StandardError => e
            warn "[Apartment] Shard deregistration failed for '#{pool_key}': #{e.class}: #{e.message}"
          end
        end
        Instrumentation.instrument(:drop, tenant: tenant)
      end

      # Run migrations for a tenant.
      def migrate(tenant, version = nil)
        Apartment::Tenant.switch(tenant) do
          ActiveRecord::Base.connection_pool.migration_context.migrate(version)
        end
      end

      # Run seeds for a tenant.
      def seed(tenant)
        Apartment::Tenant.switch(tenant) do
          seed_file = Apartment.config.seed_data_file
          return unless seed_file

          unless File.exist?(seed_file)
            raise(Apartment::ConfigurationError,
                  "Seed file '#{seed_file}' does not exist")
          end

          load(seed_file)
        end
      end

      # Whether pinned models can share the tenant's connection pool using
      # qualified table names instead of establish_connection.
      #
      # Returns false by default (separate pool). Subclasses override to
      # return true when the engine supports cross-schema/database queries,
      # gated by config.force_separate_pinned_pool.
      def shared_pinned_connection?
        false
      end

      # Whether +conn+ sits in an aborted-transaction state that every subsequent
      # statement will fail against until the transaction ends. PostgreSQL is the
      # only supported engine with such a state (PQTRANS_INERROR); MySQL fails the
      # statement and leaves the transaction usable, and its raw connection has no
      # transaction_status at all. Base is conservative: never reclassify.
      # See docs/designs/transaction-taint-detection.md (Evidence E).
      def aborted_transaction?(_conn)
        false
      end

      # Request-path fail-safe contract. The elevator wraps the
      # tenant switch; on one of these error classes it asks
      # #tenant_container_gone? whether the tenant's storage actually vanished (a
      # cross-process drop) rather than an app-level failure. An empty list
      # disables the rescue, so an adapter that does not implement the seams
      # never converts an error into a 404.
      def failsafe_error_classes
        []
      end

      # Whether +error+, raised while serving +tenant+, means the tenant's
      # container (schema/database/file) no longer exists — so the validator
      # should evict the name and the request should 404 instead of surfacing a
      # 500. Composed from a cheap error-shape check and an authoritative
      # existence probe, both conservative by default so the base adapter never
      # reclassifies. Subclasses override the seams.
      def tenant_container_gone?(error, tenant)
        return false unless container_error?(unwrap_db_error(error))

        !tenant_container_exists?(tenant)
      end

      # The statements Privileges.standard should execute for ctx.phase, or [] when
      # this engine needs none in that phase. A pure function of its inputs: build,
      # do not execute, so the SQL is unit-testable without a database.
      #
      # ConfigurationError rather than NotImplementedError. An adopter who configured
      # the standard policy on a strategy that has none made a configuration mistake,
      # and NotImplementedError descends from ScriptError, so `rescue StandardError`
      # around Tenant.create would not catch it. The NotImplementedError raises
      # elsewhere in this class mean something different: a subclass owes an
      # implementation.
      def standard_privilege_statements(_ctx, grant_to:, include_functions: true) # rubocop:disable Lint/UnusedMethodArgument
        raise(Apartment::ConfigurationError,
              "Apartment::Privileges.standard does not support #{self.class.name}. " \
              'Write a tenant_privilege_policy for this strategy; see docs/rbac.md.')
      end

      # The executing database role, for policies that need to name it explicitly
      # (PostgreSQL's ALTER DEFAULT PRIVILEGES FOR ROLE). nil where the engine has
      # no role system. Token shape differs by engine, so each adapter answers.
      def current_db_role(_connection)
        nil
      end

      # The namespace that makes the default tenant's tables reachable from any
      # tenant connection — a schema (PostgreSQL) or a database (MySQL).
      # Subclasses must implement when shared_pinned_connection? returns true.
      def pinned_table_qualifier
        raise(NotImplementedError,
              "#{self.class}#pinned_table_qualifier must be implemented when shared_pinned_connection? is true")
      end

      # Qualify a pinned model's table_name so it targets the default tenant's
      # tables from any tenant connection.
      #
      # Always assigns table_name directly. The tempting alternative — set
      # table_name_prefix and let Rails recompose — is unsound, because
      # compute_table_name only consults full_table_name_prefix on its
      # base_class? branch:
      #
      #   * a class that is not its own base_class gets base_class.table_name
      #     verbatim, so the prefix is discarded outright;
      #   * full_table_name_prefix prefers the first module parent that responds
      #     to table_name_prefix, so an engine-namespaced model ignores the
      #     prefix set on the class itself;
      #   * overwriting the prefix drops one the app set, silently retargeting
      #     the model at a different table.
      #
      # In each case the model resolves to the *tenant's* table and nothing
      # raises. Reading table_name first lets Rails compute the conventional
      # name — honouring any prefix, suffix, or nesting the app declared —
      # before we qualify the result.
      def qualify_pinned_table_name(klass)
        # Captured before the mutation below: afterwards there is no way to
        # tell a descendant's stale memo from a table it declared itself.
        inheriting = klass.apartment_descendants_inheriting_table_name
        # Evaluated before the mutation, which is what inherits_pinned_table?
        # inspects.
        mutates = pinned_qualification_mutates?(klass)
        apply_pinned_qualification(klass)
        klass.apartment_resync_descendant_table_names!(inheriting)
        verify_pinned_qualification!(klass) if mutates
      end

      # Whether qualifying +klass+ will actually change its naming. False for
      # the branch that deliberately mutates nothing, which must not be
      # verified: a subclass sharing an already-pinned base's table is correct
      # by construction, and if its base has not been qualified yet (registry
      # order) it is about to become so.
      def pinned_qualification_mutates?(klass)
        klass.abstract_class? || !inherits_pinned_table?(klass)
      end

      def apply_pinned_qualification(klass)
        return qualify_pinned_table_name_prefix(klass) if klass.abstract_class?
        return klass.apartment_mark_processed! if inherits_pinned_table?(klass)

        # Captured before the assignment below, which would otherwise make
        # every model look explicitly named.
        path = klass.apartment_explicit_table_name? ? :explicit : :computed
        original = klass.table_name
        klass.table_name = "#{pinned_table_qualifier}.#{original.sub(/\A[^.]+\./, '')}"
        klass.apartment_mark_processed!(path, (original if path == :explicit))
      end

      # Prove the qualification took effect rather than assuming it did.
      #
      # A failed qualification is otherwise indistinguishable from a successful
      # one: the model is marked processed, nothing raises, and it serves the
      # current tenant's rows. Checking the post-condition surfaces that class
      # of failure at the point it happens — including one introduced by a
      # future Rails change to the naming internals, since compute_table_name
      # is not public API.
      #
      # An abstract base has no table of its own, so it is proven through the
      # descendants its prefix was meant to reach; a `nil` name is skipped.
      #
      # The descendant set is computed here rather than reused from the resync
      # pass: that one is deliberately limited to descendants holding a memo,
      # while a descendant with no memo inherits its name lazily and can be
      # just as wrong. Descendants that declare their own table are excluded —
      # an ancestor's qualification was never meant to reach them, and
      # warn_unregistered_pinned_subclasses already reports that shape.
      # The model itself RAISES; its descendants only WARN. The asymmetry is
      # the point, and it is the same rule warn_unregistered_pinned_subclasses
      # follows: raise only on what this pass can actually prove.
      #
      # For the registered model, the check is complete and unambiguous — it
      # was just qualified, so if the name is not qualified something is
      # genuinely broken, every time, on every boot.
      #
      # For descendants it is neither. Detection walks `descendants`, so it is
      # complete under eager loading and partial under Zeitwerk lazy loading:
      # raising would fail production boots for a condition that dev never
      # reports, while still missing the descendants that load later. A warning
      # carries the same signal without making detection completeness a
      # boot-time dependency.
      def verify_pinned_qualification!(klass)
        prefix = "#{verified_pinned_qualifier}."

        name = pinned_table_name_for(klass)
        if name && !name.start_with?(prefix)
          raise(Apartment::ConfigurationError, unqualified_pinned_message(klass, name, prefix))
        end

        warn_unqualified_descendants(klass, prefix)
      end

      def warn_unqualified_descendants(klass, prefix)
        inheriting_descendants(klass).each do |sub|
          sub_name = pinned_table_name_for(sub)
          next if sub_name.nil? || sub_name.start_with?(prefix)

          warn(unqualified_pinned_message(sub, sub_name, prefix))
        end
      end

      # A model whose table_name raises cannot be verified. Say so rather than
      # skipping silently: the thesis of this check is proving rather than
      # assuming, and an unverifiable model is exactly what it must not wave
      # through unremarked.
      def pinned_table_name_for(model)
        model.table_name
      rescue StandardError => e
        warn '[Apartment] could not verify the pinned table name for ' \
             "#{model.name || model.inspect}: #{e.class}: #{e.message}"
        nil
      end

      # A nil or empty qualifier produces a bare ".table", which start_with?(".")
      # would happily accept — the check proving nothing in exactly the case it
      # exists for. On MySQL this is a connection config with no 'database' key.
      def verified_pinned_qualifier
        qualifier = pinned_table_qualifier
        return qualifier unless qualifier.nil? || qualifier.to_s.empty?

        raise(Apartment::ConfigurationError,
              "[Apartment] #{self.class}#pinned_table_qualifier is #{qualifier.inspect}, so pinned " \
              'models were qualified to a bare ".table" and would not resolve. On MySQL this ' \
              "usually means the connection config carries no 'database' key.")
      end

      def inheriting_descendants(klass)
        return [] unless klass.respond_to?(:descendants)

        klass.descendants.select do |sub|
          sub.respond_to?(:apartment_inherited_table_name) &&
            !awaiting_own_qualification?(sub) &&
            sub.table_name == sub.apartment_inherited_table_name
        rescue StandardError => e
          warn "[Apartment] could not classify pinned descendant #{sub.name || sub.inspect}: " \
               "#{e.class}: #{e.message}"
          false
        end
      end

      # A descendant that is registered but not yet processed gets qualified on
      # its own turn, by direct assignment, which reaches names the ancestor's
      # broadcast cannot. Registry order is always parent-first — defining a
      # subclass loads its parent, and pin_tenant registers during class-body
      # execution — so verifying the base's descendants would otherwise raise
      # on a model that is about to become correct, aborting the very iteration
      # that would have fixed it. That is the remedy this check's own error
      # message prescribes, so it has to keep working.
      def awaiting_own_qualification?(klass)
        Apartment.pinned_models.include?(klass) && !klass.apartment_pinned_processed?
      end

      def unqualified_pinned_message(model, name, prefix)
        "[Apartment] #{model.name || model.inspect} is pinned but its table name " \
          "(#{name.inspect}) is not qualified with #{prefix.inspect}, so it would read the " \
          'current tenant instead of the default tenant. This usually means Rails composed ' \
          "the name from something the qualifier cannot reach — a module parent's " \
          'table_name_prefix, or a base class outside the pinned hierarchy. Call pin_tenant ' \
          'on the model directly, or set self.table_name to an already-qualified name.'
      end

      # An abstract class has no table of its own — table_name is nil — so
      # there is nothing to assign. Pinning one is a supported pattern (an
      # abstract `connects_to` base is pinned so Apartment does not build
      # tenant pools for it), and its qualifier still has to reach the concrete
      # descendants that inherit the pin.
      #
      # Those descendants are never qualified directly: pin_tenant early-returns
      # once any superclass is pinned (apartment_pinned? walks the chain), so
      # they are never registered and process_pinned_models never sees them.
      # table_name_prefix is a class_attribute, so setting it here broadcasts
      # down the inheritance chain and each descendant composes it in its own
      # compute_table_name. Any prefix the app set is preserved rather than
      # overwritten, so `myapp_` becomes `<qualifier>.myapp_`.
      #
      # This is the one place the prefix mechanism is still correct, because
      # here it is a broadcast to other classes rather than an attempt to
      # qualify this class's own name.
      def qualify_pinned_table_name_prefix(klass)
        original_prefix = klass.table_name_prefix
        klass.table_name_prefix = "#{pinned_table_qualifier}.#{original_prefix}"
        klass.apartment_mark_processed!(:prefix, original_prefix)
      end

      # Whether +klass+ reaches its table through an already-pinned base class
      # and so needs no qualification of its own. Rails resolves a subclass's
      # table through base_class.table_name, which the base's qualification
      # already covers; assigning here would freeze a copy of the base's
      # qualified name onto the child and desynchronise the two on teardown.
      #
      # Scoped narrowly on purpose. A subclass that declares its own table —
      # the transitional shape when migrating an STI child off a pinned
      # parent's table — is NOT covered and qualifies normally, because the
      # parent's qualification cannot reach a different table. And a subclass
      # whose base class is not pinned (e.g. an app model extending a gem's
      # model) is not covered either, which is the case that motivated
      # qualifying by assignment in the first place.
      def inherits_pinned_table?(klass)
        return false if klass.base_class?
        return false if klass.apartment_explicit_table_name?

        base = klass.base_class
        base.respond_to?(:apartment_pinned?) && base.apartment_pinned?
      end

      # Process all pinned models. When shared_pinned_connection? is true, qualifies
      # table names for shared pool routing. Otherwise, establishes separate connections.
      def process_pinned_models
        return if Apartment.pinned_models.empty?

        Apartment.pinned_models.each do |klass|
          process_pinned_model(klass)
        rescue StandardError => e
          raise(Apartment::ConfigurationError,
                "Failed to process pinned model #{klass.name}: #{e.class}: #{e.message}")
        end

        warn_unregistered_pinned_subclasses
      end

      # Warn about subclasses of a pinned model that declare their own table and
      # were never registered. Such a class inherits apartment_pinned? through
      # the superclass walk but gets no qualification, so on a shared-connection
      # adapter it silently reads the *tenant's* table — and on a separate-pool
      # adapter a genuinely tenant-scoped one silently reads the default's. The
      # shape is transitional (migrating an STI child off a pinned parent's
      # table), which is exactly when a silent read is most costly: the symptom
      # looks like a botched backfill.
      #
      # Detection walks descendants, so it is complete under eager loading
      # (production boot, CI) and partial under Zeitwerk lazy loading. That is
      # tolerable for a warning and would not be for a raise — which is why this
      # warns rather than raising.
      # descendants is transitive, so every pinned class in one inheritance
      # chain sees the same unregistered descendant. Deduplicate, and attribute
      # each warning to the *nearest* pinned ancestor — the one whose pin the
      # subclass actually inherits — so the message is deterministic rather than
      # dependent on registry iteration order.
      def warn_unregistered_pinned_subclasses
        # Snapshot the registry and walk it outside its own lock. Concurrent::Set
        # synchronizes every method on CRuby, #each included, so iterating in
        # place would hold a process-wide monitor across descendant walking and
        # stderr I/O. Same leaf-lock discipline as Patches::ConnectionRegistry.
        pinned = Apartment.pinned_models.to_a
        registered = Set.new(pinned)
        seen = Set.new

        pinned.each do |klass|
          next unless klass.respond_to?(:descendants)

          klass.descendants.each do |sub|
            check_pinned_subclass(klass, sub, registered) if seen.add?(sub)
          end
        end
      end

      # Advisory only: this runs from process_pinned_models, which Tenant.init
      # calls in after_initialize, so it must never be able to fail a boot.
      # Rails' naming machinery raises on shapes we do not control — an
      # anonymous descendant has no model_name, and Class.new(SomeBase) is
      # everywhere in test suites.
      def check_pinned_subclass(klass, sub, registered)
        return unless unregistered_pinned_subclass?(sub, registered)

        warn_unqualified_subclass(nearest_pinned_ancestor(sub, registered) || klass, sub)
      rescue StandardError => e
        warn "[Apartment] could not check pinned subclass #{sub.inspect}: #{e.class}: #{e.message}"
      end

      # The closest registered ancestor above +klass+, i.e. the pin it inherits.
      def nearest_pinned_ancestor(klass, registered)
        ancestor = klass.superclass
        while ancestor.is_a?(Class) && ancestor < ActiveRecord::Base
          return ancestor if registered.include?(ancestor)

          ancestor = ancestor.superclass
        end
        nil
      end

      def unregistered_pinned_subclass?(sub, registered)
        return false if registered.include?(sub)
        # Anonymous classes have no model_name for Rails to compute a table
        # from, and nothing actionable to name in a warning.
        return false if sub.name.nil?
        return false unless sub.respond_to?(:apartment_explicit_table_name?)
        return false if sub.abstract_class?

        sub.apartment_explicit_table_name?
      end

      def warn_unqualified_subclass(klass, sub)
        warn "[Apartment] #{sub.name || sub.inspect} inherits a pin from " \
             "#{klass.name || klass.inspect} but declares its own table " \
             "(#{sub.table_name}) and was never registered, so it is not qualified. " \
             "Call pin_tenant on it if it should read the default tenant's data."
      end

      # Process a single pinned model. Called by process_pinned_models (batch)
      # and by Apartment::Model.pin_tenant (when activated? is true).
      #
      # When shared_pinned_connection? is true, qualifies the table name so
      # the model uses the tenant's pool (preserving transactional integrity).
      # Otherwise, establishes a separate connection pool (required when
      # cross-database queries are impossible).
      def process_pinned_model(klass)
        # Ensure the concern is included — models registered via the
        # excluded_models shim may not have it yet. Uses apartment_mark_pinned!
        # (not pin_tenant) to avoid recursion back into process_pinned_model.
        unless klass.respond_to?(:apartment_pinned_processed?)
          klass.include(Apartment::Model)
          klass.apartment_mark_pinned!
        end

        return if klass.apartment_pinned_processed?

        # A subclass that reaches its table through an already-pinned base needs
        # nothing on either path. Qualifying would freeze a copy of the base's
        # name onto it; establishing a connection would hand it a *different*
        # pool from its parent, splitting two classes that share one physical
        # table across connections and breaking transactional integrity between
        # them. Mark processed with a nil path so teardown skips it too.
        return klass.apartment_mark_processed! if inherits_pinned_table?(klass)

        if shared_pinned_connection?
          qualify_pinned_table_name(klass)
        else
          klass.establish_connection(pinned_model_config)
          klass.apartment_mark_processed!
        end
      end

      # Deprecated: use process_pinned_models instead.
      def process_excluded_models
        warn '[Apartment] DEPRECATION: process_excluded_models is deprecated. ' \
             'Use Apartment::Model with pin_tenant instead.'
        process_pinned_models
      end

      # Environmentify a tenant name based on config.
      # :prepend/:append require Rails to be defined (for Rails.env).
      def environmentify(tenant)
        case Apartment.config.environmentify_strategy
        when :prepend
          "#{rails_env}_#{tenant}"
        when :append
          "#{tenant}_#{rails_env}"
        when nil
          tenant.to_s
        else
          # Callable
          Apartment.config.environmentify_strategy.call(tenant)
        end
      end

      # The physical identifier used to address this tenant at connection time:
      # the database name for database-per-tenant strategies (environmentified).
      # validated_connection_config validates THIS name so the pool-resolution
      # path agrees with what the connection actually targets. Schema-per-tenant
      # overrides this to the raw tenant (schemas are named directly).
      def physical_tenant_name(tenant)
        environmentify(tenant)
      end

      # Default tenant from config.
      def default_tenant
        Apartment.config.default_tenant
      end

      private

      # Validate the raw tenant for pool-key safety: it becomes "#{tenant}:#{role}"
      # in the pool key, so a colon / whitespace / NUL there breaks PoolManager's
      # prefix and suffix matching and could evict the wrong tenant's pool.
      # Validated in addition to physical_tenant_name (which carries the engine
      # rules) because a callable environmentify_strategy could transform an
      # unsafe character out of the physical name while the raw name still reaches
      # the pool key. to_s first so a non-String tenant is stringified, not
      # rejected (it is the value the pool key interpolates anyway).
      def validate_pool_key_safety!(tenant)
        TenantNameValidator.validate_common!(tenant.to_s)
      end

      protected

      def create_tenant(tenant)
        raise(NotImplementedError)
      end

      def drop_tenant(tenant)
        raise(NotImplementedError)
      end

      private

      # --- Missing-tenant fail-safe seams -------------------------------------

      # Does +error+ look like a missing-container error for this engine?
      # Base: never, so the default adapter classifies nothing.
      def container_error?(_error)
        false
      end

      # Authoritative check that the tenant's container exists. Base: assume it
      # does, so an unimplemented adapter never evicts a live tenant.
      def tenant_container_exists?(_tenant)
        true
      end

      # ConnectionHandling wraps non-Apartment errors raised during pool
      # resolution in Apartment::ApartmentError with the original as #cause; the
      # schema-strategy query error arrives unwrapped. Inspect the cause when
      # present so both shapes classify the same.
      def unwrap_db_error(error)
        error.is_a?(Apartment::ApartmentError) && error.cause ? error.cause : error
      end

      # Every DDL step of a create runs on config.ddl_role when one is set: the
      # container, both privilege-policy phases, and any schema import.
      #
      # PostgreSQL scopes an ALTER DEFAULT PRIVILEGES rule with no FOR ROLE to the
      # role that EXECUTES it, never to the role named in the GRANT. Recording such a
      # rule under one role while migrations create tables under another leaves every
      # migration-created table outside it — the same missing-grant failure as running
      # the migrations themselves on the writing role, only it surfaces later, from
      # whatever ordinary query first touches the new table.
      #
      # Two further constraints keep the steps in ONE wrap rather than wrapping only
      # the policy. The container is owned by whoever created it, and ALTER on a table
      # needs ownership. And a policy that hands the app role USAGE plus DML, never
      # CREATE, leaves a schema import on the writing role unable to add tables to a
      # container it does not own.
      #
      # Seeding stays outside the wrap: it writes rows, and rows carry no ownership.
      def run_tenant_ddl(tenant)
        MigrationRole.wrap do
          create_tenant(tenant)
          db_role = resolve_privilege_db_role
          apply_privilege_policy(tenant, :before_schema_load, db_role)
          import_schema(tenant) if Apartment.config.schema_load_strategy
          apply_privilege_policy(tenant, :after_schema_load, db_role)
        end
      ensure
        discard_ddl_role_pool(tenant)
      end

      # import_schema switches into the new tenant, and a pool key carries the role it
      # was resolved under (Patches::ConnectionHandling), so that switch registers a
      # DDL-role pool nothing else will claim.
      #
      # Two narrowings, both about not disconnecting somebody else's work. This
      # discards a single key rather than calling PoolManager#evict_by_role, which
      # Migrator uses at the end of a run and which would also drop a pool another
      # thread is migrating through. And it skips a pool that is still in use, since
      # the SAME key is what a concurrent migration of this tenant leases: creating a
      # tenant that a Migrator run is already covering would otherwise pull the pool
      # out from under it. What lingers instead is one idle pool, which the reaper
      # collects on its own terms.
      #
      # The release comes first because our own import_schema lease is on this pool;
      # without it the in-use check would see this thread and skip every discard.
      def discard_ddl_role_pool(tenant)
        role = Apartment.config.ddl_role
        return unless role

        pool_key = Apartment.pool_key(tenant, role)
        pool = Apartment.pool_manager&.peek(pool_key)
        release_pool_connection(tenant, pool)
        return if Apartment.pool_in_use?(pool)

        Apartment.deregister_shard(pool_key)
      end

      # Releasing a lease must not mask the create's own outcome, and it has thrown
      # before: see Migrator#release_tenant_pool_connection, which learned the same
      # lesson from a ThreadError during teardown.
      def release_pool_connection(tenant, pool)
        pool&.release_connection
      rescue StandardError => e
        warn "[Apartment] Connection release failed for '#{tenant}': #{e.class}: #{e.message}"
      end

      # Schema import and seeding switch into the tenant being created, and resolving
      # that pool is where ConnectionHandling runs its pending-migration check. The
      # container is seconds old and has of course run no migration, so the check
      # fires against the very thing create is building and create raises instead of
      # finishing. Only reproducible where the check is live — check_pending_migrations
      # true (the default) and Rails.env.local? — so development and test, which is
      # where creating a tenant by hand is most common.
      #
      # A switch alone does not trip it; the pool is resolved by the first query. That
      # is why the failure looks intermittent across configurations: it needs a schema
      # import, or seeds that actually touch the database.
      #
      # Migrator suppresses the same check with the same flag around its own switches.
      # The previous value is restored rather than cleared, so a create nested inside a
      # migration — an adopter's :create callback, a create-then-migrate helper — does
      # not disarm the migration's own suppression on the way out.
      #
      # The window covers the whole :create callback chain, deliberately. Provisioning
      # rows in the tenant just created is what those callbacks are for, and with the
      # default schema_load_strategy of nil that tenant has no schema_migrations yet, so
      # a narrower window would leave every such callback raising the very error this
      # method exists to prevent.
      #
      # The cost of that width: Current.migrating is a boolean, not tenant-scoped, so a
      # callback that switches to some OTHER cold tenant also skips that tenant's check
      # and leaves its pool warm and unchecked. Accepted rather than overlooked. The
      # check is a development convenience (config.check_pending_migrations plus
      # Rails.env.local?), the effect is one missed warning until that pool is evicted,
      # and closing it properly means making the flag tenant-aware — which Migrator also
      # sets, per worker, so it is a change to a shared contract and belongs on its own.
      def suppressing_pending_migration_check
        previous = Apartment::Current.migrating
        Apartment::Current.migrating = true
        yield
      ensure
        Apartment::Current.migrating = previous
      end

      # The database role both phases report, resolved once per create inside the
      # ddl_role wrap so the round trip is paid once. nil when no policy is
      # configured: an adopter without one should pay nothing at all.
      #
      # Deliberately a local in run_tenant_ddl rather than an ivar. Apartment.adapter
      # is one instance for the life of the process, so an adapter ivar is shared
      # across concurrent creates — thread B could read the role thread A resolved and
      # name it in ALTER DEFAULT PRIVILEGES FOR ROLE while creating objects as its
      # own. That is the bug this design exists to prevent, arriving through shared
      # state, and it is invisible whenever both creates share a ddl_role.
      def resolve_privilege_db_role
        return unless Apartment.config.tenant_privilege_policy

        current_db_role(ActiveRecord::Base.connection)
      end

      # Invoke the adopter's policy for one phase. Two calls per create, because
      # position is policy: a default-privileges-only model has to record its rules
      # before the schema import or imported tables fall outside them, while a model
      # granting existing objects has to run after. See
      # docs/designs/v4-rbac-contract.md.
      #
      # A fresh context per phase; the two share nothing but the resolved role, which
      # arrives as an argument.
      def apply_privilege_policy(tenant, phase, db_role)
        policy = Apartment.config.tenant_privilege_policy
        return unless policy

        policy.call(
          Privileges::Context.new(
            tenant: tenant,
            container_name: physical_tenant_name(tenant),
            connection: ActiveRecord::Base.connection,
            db_role: db_role,
            phase: phase
          )
        )
      end

      # Connection config with string keys (used by subclasses to build tenant configs).
      def base_config
        connection_config.transform_keys(&:to_s)
      end

      # Cap the tenant pool's max checkout size to Apartment.config.tenant_pool_size
      # when configured. Defaults to nil — the tenant pool inherits the base/default
      # pool's `pool:` (the app's DB_POOL_SIZE), preserving pre-4.0.0.alpha3 behavior.
      # Set tenant_pool_size to size each per-tenant pool independently of the app pool
      # (e.g. to bound total connections across many schema-per-tenant pools). The config
      # is string-keyed here; HashConfig symbolizes it and reads `:pool` for the size.
      def apply_tenant_pool_size(config)
        size = Apartment.config.tenant_pool_size
        return config unless size

        config.merge('pool' => size)
      end

      # Connection config for pinned models on the separate-pool path.
      # For schema strategy, pins schema_search_path to the default tenant
      # (plus persistent schemas) so the connection resolves tables and FK
      # constraints in the correct schema.
      # For database strategies, returns base_config unchanged.
      def pinned_model_config
        config = base_config
        return config unless Apartment.config.tenant_strategy == :schema

        persistent = Apartment.config.postgres_config&.persistent_schemas || []
        search_path = [default_tenant, *persistent].map { |s| %("#{s}") }.join(',')
        config.merge('schema_search_path' => search_path)
      end

      def rails_env
        unless defined?(Rails)
          raise(Apartment::ConfigurationError,
                'environmentify_strategy :prepend/:append requires Rails to be defined')
        end
        Rails.env
      end

      def deregister_shard_from_ar_handler(pool_key)
        Apartment.deregister_shard(pool_key)
      end

      def import_schema(tenant)
        Apartment::Tenant.switch(tenant) do
          schema_file = resolve_schema_file
          case Apartment.config.schema_load_strategy
          when :schema_rb
            load(schema_file)
          when :sql
            ActiveRecord::Tasks::DatabaseTasks.load_schema(
              ActiveRecord::Base.connection_db_config, :sql, schema_file
            )
          end
        end
      rescue StandardError => e
        raise(Apartment::SchemaLoadError,
              "Failed to load schema for tenant '#{tenant}': #{e.class}: #{e.message}")
      end

      def resolve_schema_file
        custom = Apartment.config.schema_file
        return custom if custom

        if defined?(Rails) && Rails.respond_to?(:root) && Rails.root
          Rails.root.join('db/schema.rb').to_s
        else
          'db/schema.rb'
        end
      end
    end
  end
end
