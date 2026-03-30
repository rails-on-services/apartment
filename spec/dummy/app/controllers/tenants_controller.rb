# frozen_string_literal: true

class TenantsController < ApplicationController
  def show
    render(json: {
             tenant: Apartment::Tenant.current,
             user_count: User.count,
           })
  end
end
