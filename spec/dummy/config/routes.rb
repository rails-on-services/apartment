# frozen_string_literal: true

Dummy::Application.routes.draw do
  get '/tenant_info' => 'tenants#show'
  root to: 'tenants#show'
end
