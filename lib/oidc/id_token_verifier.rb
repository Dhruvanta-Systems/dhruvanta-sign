# frozen_string_literal: true

module Oidc
  # The id_token of a sign-in or a step-up.
  module IdTokenVerifier
    STEP_UP_SKEW = 5

    module_function

    # @param nonce [String] the nonce this login stored
    # @param not_before [Integer, nil] the person must have authenticated at or after this time
    def verify(jwt, nonce:, not_before: nil)
      claims = TokenVerifier.verify_signature(jwt)

      TokenVerifier.check_issuer_and_audience!(claims)
      TokenVerifier.check_times!(claims)
      raise Error, 'nonce_mismatch' unless secure_equal?(claims['nonce'], nonce)
      raise Error, 'missing_subject' if claims['sub'].blank?
      raise Error.new('email_not_verified', :forbidden) unless claims['email_verified'] == true
      raise Error, 'missing_email' if claims['email'].blank?

      check_auth_time!(claims, not_before)

      claims
    end

    def check_auth_time!(claims, not_before)
      return unless not_before
      raise Error, 'authentication_not_fresh' unless claims['auth_time'].is_a?(Numeric) &&
                                                     claims['auth_time'] >= not_before.to_i - STEP_UP_SKEW
    end

    def secure_equal?(actual, expected)
      actual.to_s.present? && expected.to_s.present? && ActiveSupport::SecurityUtils.secure_compare(actual.to_s, expected.to_s)
    end
  end
end
