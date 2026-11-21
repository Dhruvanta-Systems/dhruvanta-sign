# frozen_string_literal: true

module Oidc
  # OpenID Connect Back-Channel Logout 1.0. The provider POSTs a logout_token (a JWT
  # of type logout+jwt); every session of the named provider session is revoked.
  #
  # The token is refused unless its signature, typ, iss, aud, exp/iat and events claim
  # are right and it carries no nonce. A jti is accepted once, remembered in the
  # database table shared by every process.
  module BackchannelLogout
    EVENT = 'http://schemas.openid.net/event/backchannel-logout'
    MAX_LIFETIME = 600

    module_function

    # @return [Integer] how many sessions were revoked
    # @raise [Oidc::Error]
    def call(logout_token)
      claims = TokenVerifier.verify_signature(logout_token.to_s, typ: 'logout+jwt')
      validate!(claims)

      ActiveRecord::Base.transaction do
        raise Error, 'logout_token_replayed' unless OidcLogoutToken.claim!(issuer: Config.issuer, jti: claims['jti'].to_s)

        OidcSession.revoke_for!(issuer: Config.issuer, sid: claims['sid'].presence, sub: claims['sub'].presence)
      end
    end

    def validate!(claims)
      TokenVerifier.check_issuer_and_audience!(claims)
      TokenVerifier.check_times!(claims, max_age: MAX_LIFETIME)

      raise Error, 'logout_token_has_nonce' if claims.key?('nonce')
      raise Error, 'missing_event' unless claims['events'].is_a?(Hash) && claims['events'].key?(EVENT)
      raise Error, 'missing_jti' if claims['jti'].blank?
      raise Error, 'missing_subject_and_sid' if claims['sid'].blank? && claims['sub'].blank?
    end
  end
end
