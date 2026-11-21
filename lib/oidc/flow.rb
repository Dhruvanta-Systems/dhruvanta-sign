# frozen_string_literal: true

module Oidc
  # The authorization code flow with PKCE (S256), state and nonce.
  #
  # `start` stores the login's secrets in the (encrypted, server-signed) browser
  # session, never in a URL; `complete` takes them out again, so each is used once.
  module Flow
    Result = Struct.new(:claims, :id_token, :flow, keyword_init: true)

    module_function

    # @param store [#[]=, #delete] the Rails session
    # @param step_up [Hash, nil] { action:, action_id:, nonce: } for a step-up
    # @return [String] the URL to send the browser to
    def start(store, return_to:, step_up: nil)
      verifier = SecureRandom.urlsafe_base64(48)
      flow = { 'state' => SecureRandom.urlsafe_base64(32), 'nonce' => step_up&.fetch(:nonce) || SecureRandom.urlsafe_base64(32),
               'verifier' => verifier, 'return_to' => return_to, 'started_at' => Time.now.to_i,
               'step_up' => step_up&.slice(:action, :action_id)&.stringify_keys }.compact
      store[:oidc_flow] = flow

      Provider.client.authorization_uri(authorization_params(flow, step_up))
    end

    def authorization_params(flow, step_up)
      params = { scope: Config.scopes, state: flow['state'], nonce: flow['nonce'], code_challenge: challenge(flow['verifier']),
                 code_challenge_method: 'S256' }
      if step_up
        params[:max_age] = 0
        params[:acr_values] = Config.step_up_acr
      end

      params
    end

    def challenge(verifier)
      Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
    end

    # @param params [Hash] the callback's query parameters
    # @return [Result]
    # @raise [Oidc::Error, Oidc::ProviderError]
    def complete(store, params)
      flow = store.delete(:oidc_flow)
      raise Error, 'no_login_in_progress' unless flow.is_a?(Hash)

      check_state!(flow, params)
      check_issuer!(params)
      raise ProviderError.new(params[:error], params[:error_description]) if params[:error].present?
      raise Error, 'missing_code' if params[:code].blank?

      id_token = exchange(params[:code], flow['verifier'])
      claims = IdTokenVerifier.verify(id_token, nonce: flow['nonce'], not_before: (flow['started_at'] if flow['step_up']))

      Result.new(claims:, id_token:, flow:)
    end

    def check_state!(flow, params)
      state = params[:state].to_s

      raise Error, 'state_mismatch' if state.empty? || !ActiveSupport::SecurityUtils.secure_compare(state, flow['state'].to_s)
    end

    # RFC 9207: the authorization response names its issuer, and it must be ours.
    def check_issuer!(params)
      if params.key?(:iss)
        raise Error, 'issuer_mismatch' unless params[:iss].to_s == Config.issuer
      elsif Provider.iss_in_response_required?
        raise Error, 'issuer_missing'
      end
    end

    def exchange(code, verifier)
      client = Provider.client
      client.authorization_code = code
      token = client.access_token!(client_auth_method: Provider.token_auth_method, code_verifier: verifier)
      id_token = token.id_token
      raise Error.new('missing_id_token', :bad_gateway) if id_token.blank?

      id_token.is_a?(String) ? id_token : id_token.to_s
    rescue Rack::OAuth2::Client::Error => e
      Rails.logger.warn("Oidc token request refused: #{e.response[:error]}")
      raise Error.new('token_request_failed', :bad_gateway, 'The sign-in could not be completed.')
    rescue Faraday::Error => e
      Rails.logger.warn("Oidc token request failed: #{e.class}")
      raise Error.new('token_request_failed', :service_unavailable, 'The sign-in service is unavailable.')
    end
  end
end
