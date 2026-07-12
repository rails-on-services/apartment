# frozen_string_literal: true

module Apartment
  module Patches
    # Keeps ActiveRecord's class-level Model.sequence_name memoization
    # schema-agnostic under pool-per-tenant.
    #
    # Rails resolves default_sequence_name via pg_get_serial_sequence with an
    # unqualified table name, so PostgreSQL answers through the current
    # connection's search_path and returns a schema-QUALIFIED name — the schema
    # of whichever tenant's pool happened to resolve it first. ActiveRecord then
    # memoizes that value once per model class, process-wide. Consumers that
    # render it into SQL (activerecord-import prefetches primary keys as a
    # literal nextval(Model.sequence_name)) would draw ids from the
    # first-resolver tenant's sequence in every tenant: wrong-tenant ids, silent
    # sequence drift, and eventual PG::UniqueViolation.
    #
    # Stripping the connection's own current_schema prefix makes the memoized
    # value schema-agnostic: nextval('widgets_id_seq') re-resolves through each
    # pool's search_path, per tenant — the same invariant v4 relies on for table
    # names (see docs/designs/v4-connection-model-rationale.md). A prefix naming
    # any OTHER schema is preserved on purpose: persistent-schema tables and
    # pinned models (whose table names are default_tenant-qualified and may
    # execute on a shared tenant connection) are only correct BECAUSE they stay
    # qualified.
    #
    # v3 shipped this guarantee as PostgreSqlAdapterPatch; it was lost in the
    # Phase 2.5 v3 deletion (PR #356). Reset-on-switch is not an alternative:
    # v4 serves tenants concurrently in one process, so only a schema-agnostic
    # memoized value can be correct.
    module PostgresqlSequenceName
      def default_sequence_name(table_name, primary_key = 'id')
        res = super
        return res if res.nil?
        # A schema-qualified table name is a PINNED model: Apartment qualifies
        # those to the default tenant, and they resolve on whatever connection is
        # current (the schema strategy shares the tenant's connection). Its
        # sequence must stay qualified — stripping here is the mirror-image bug,
        # because an unqualified name would later re-resolve against a *tenant's*
        # search_path and draw ids from that tenant's stale copy of the pinned
        # table's sequence. That order is the common one, not a corner case:
        # pinned models are typically first touched at boot, on the default pool.
        # v3 guarded the same case by force-adding the default_tenant prefix.
        return res if table_name.to_s.include?('.')

        # Routed table: drop whatever schema PostgreSQL qualified the sequence
        # with — not just the connection's own. The two differ when the tenant
        # schema is missing the table and search_path falls through to a schema
        # that has it: the resolved sequence then names the FALLBACK schema, and
        # preserving that would memoize it process-wide, so every tenant —
        # including correctly-migrated ones — would draw from the fallback's
        # sequence forever. Unqualified is the only value that lets the sequence
        # re-resolve per pool exactly like the table name does.
        #
        # Parsed with AR's own splitter (rather than by hand) because it is what
        # produced `res`, so it round-trips quoting and dotted identifiers.
        ActiveRecord::ConnectionAdapters::PostgreSQL::Utils
          .extract_schema_qualified_name(res).identifier
      end
    end
  end
end
