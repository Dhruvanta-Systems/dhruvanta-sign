# frozen_string_literal: true

# AUTH_MODE=external is an OpenID Connect relying party: a confidential client that
# signs people in with the authorization code flow (PKCE S256, state, nonce, the
# RFC 9207 issuer check), verifies the id_token against the provider's keys, keeps a
# server-side session registry keyed by the provider's session id, and supports
# RP-initiated and back-channel logout and step-up re-authentication.
#
# It works with any standards-compliant provider; see Oidc::Config for the settings.
# The protocol plumbing (discovery, the authorization request, the token request and
# JWS verification) is the openid_connect gem (MIT, with rack-oauth2 and json-jwt).
require 'openid_connect'

module Oidc
  # A refusal with a short machine code and the HTTP status to answer with. The
  # message is safe to show to a person.
  class Error < StandardError
    attr_reader :code, :http_status

    def initialize(code, http_status = :bad_request, message = nil)
      super(message || code.to_s.tr('_', ' '))
      @code = code
      @http_status = http_status
    end
  end

  # The provider answered the authorization request with an error (access_denied,
  # login_required, ...): "not signed in", never a crash.
  class ProviderError < Error
    def initialize(error, description = nil)
      status = error.to_s == 'access_denied' ? :forbidden : :unauthorized
      super("provider_#{error}", status, description.presence || "The sign-in was not completed (#{error}).")
    end
  end
end
