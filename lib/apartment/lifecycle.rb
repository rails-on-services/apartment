# frozen_string_literal: true

require_relative 'instrumentation'

module Apartment
  # Public hooks for telling Apartment that a tenant was created or dropped
  # outside the gem's own lifecycle path (e.g., a schema provisioned by raw
  # psql, pg_restore, or a separate migration job).
  #
  # Apartment::Tenant.create / .drop already publish these events; call these
  # helpers only when the lifecycle happens through some other path. The
  # in-process TenantValidator subscribes to both events and updates its
  # positive set, so the next request for that tenant doesn't pay a
  # rebuild-on-miss.
  #
  #   Apartment::Lifecycle.notify_created('acme')
  #   Apartment::Lifecycle.notify_dropped('acme')
  #
  # Updates only the calling Ruby process's validator. A worker-tier job that
  # provisions a schema and notifies here will not reach a separate web-tier
  # process — see docs/designs/elevator-tenant-validation.md (Multi-process
  # deployments) and the cross-process invalidation tracking issue.
  module Lifecycle
    def self.notify_created(tenant)
      Instrumentation.instrument(:create, tenant: tenant)
    end

    def self.notify_dropped(tenant)
      Instrumentation.instrument(:drop, tenant: tenant)
    end
  end
end
