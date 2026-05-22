# frozen_string_literal: true

Dummy::Application.configure do
  config.cache_classes = true
  config.eager_load = false
  config.consider_all_requests_local = true
  config.action_controller.perform_caching = false
  # :rescuable (the modern Rails test-env default) renders exceptions listed
  # in rescue_responses as their mapped status — so Apartment::TenantNotFound
  # surfaces as a real 404 — while still re-raising anything unexpected.
  config.action_dispatch.show_exceptions = :rescuable
  config.active_support.deprecation = :stderr
end
