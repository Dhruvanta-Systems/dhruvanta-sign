# frozen_string_literal: true

module Oidc
  # Step-up: a sensitive action needs a fresh, stronger proof than the sign-in gave.
  #
  # The person is sent back to the provider with acr_values=OIDC_STEP_UP_ACR and
  # max_age=0 and a nonce bound to ONE action and ONE session:
  #
  #   nonce = HMAC(secret, action_id + session_id)
  #
  # The result counts for that one action only if its acr is at least the required
  # one, auth_time is not before the request, the nonce is the action's and the same
  # person answered. The proof is used once.
  module StepUp
    # The actions that can be made to need step-up (OIDC_STEP_UP_ACTIONS lists the ones that do).
    ACTIONS = %w[api_token account_deletion webhooks role_change].freeze
    PROOF_TTL = 10.minutes

    module_function

    def nonce(action_id, session_id)
      OpenSSL::HMAC.hexdigest('SHA256', Rails.application.secret_key_base, "#{action_id}:#{session_id}")
    end

    # Records the proof in the browser session after the provider answered.
    def grant!(store, action:)
      store[:oidc_step_up] = { 'action' => action.to_s, 'at' => Time.now.to_i }
    end

    # @return [Boolean] true once for a fresh proof of this action
    def consume!(store, action)
      proof = store.delete(:oidc_step_up)

      proof.is_a?(Hash) && proof['action'] == action.to_s && Time.now.to_i - proof['at'].to_i <= PROOF_TTL
    end
  end
end
