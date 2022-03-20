if ActiveStorage::VERSION::MAJOR >= 7
  module ActiveStorage::SetBlob # :nodoc:
    extend ActiveSupport::Concern

    included do
      before_action :set_blob
    end

    private
      def set_blob
        current_tenant = Apartment::Tenant.current
        Apartment::Tenant.switch!(current_tenant)
        @blob = blob_scope.find_signed!(params[:signed_blob_id] || params[:signed_id])
      rescue ActiveSupport::MessageVerifier::InvalidSignature
        head :not_found
      end
  end
end
