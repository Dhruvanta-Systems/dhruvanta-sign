# frozen_string_literal: true

require 'openssl'

module Api
  class IdentityVerificationController < ActionController::Base
    skip_forgery_protection

    def start
      render_disabled({ field_uuid: params[:field_uuid] }, status: :service_unavailable)
    end

    def complete
      render_disabled({ completed: false }, status: :not_found)
    end

    def callback
      render_disabled({ callback_accepted: false, provider: params[:provider] }, status: :service_unavailable)
    end

    private

    def render_disabled(extra_payload = {}, status:)
      response.headers['Cache-Control'] = 'no-store'
      Rails.logger.info(disabled_log_payload.to_json)

      render json: disabled_payload.merge(extra_payload), status:
    end

    def disabled_log_payload
      {
        event: 'identity_verification.disabled',
        action: action_name,
        provider: params[:provider],
        field_uuid: params[:field_uuid],
        request_id: request.request_id,
        source_ip_hash: source_ip_hash
      }.compact
    end

    def source_ip_hash
      return if request.remote_ip.blank?

      OpenSSL::HMAC.hexdigest('SHA256', Rails.application.secret_key_base.to_s, request.remote_ip)
    end

    def disabled_payload
      {
        available_methods: [],
        verification_available: false,
        disabled_reason: 'public_identity_verification_backend_missing',
        error: 'Identity verification is not available for this signing form yet. Please contact the sender.'
      }
    end
  end
end
