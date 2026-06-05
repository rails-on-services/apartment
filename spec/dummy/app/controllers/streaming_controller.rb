# frozen_string_literal: true

# Minimal ActionController::Live action used by
# spec/integration/v4/live_streaming_spec.rb to verify that queries
# executed inside the streaming thread route to the tenant the request
# entered with. The action queries User.count once, writes a single SSE
# data frame with the tenant name plus row count, and closes the stream.
class StreamingController < ApplicationController
  include ActionController::Live

  def show
    response.headers['Content-Type'] = 'text/event-stream'
    response.headers['Cache-Control'] = 'no-cache'

    payload = { tenant: Apartment::Tenant.current, user_count: User.count }
    response.stream.write("data: #{payload.to_json}\n\n")
  ensure
    response.stream.close
  end
end
