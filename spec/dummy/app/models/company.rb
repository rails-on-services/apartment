# frozen_string_literal: true

# The tenant registry — global, lives in the default tenant. Pinned via the
# v4 Apartment::Model API (replaces the deprecated config.excluded_models).
class Company < ApplicationRecord
  include Apartment::Model

  pin_tenant
end
