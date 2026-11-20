# frozen_string_literal: true

module JwtSso
  # Runtime configuration for the generic JWT single-sign-on receiver. Everything
  # comes from the environment and is read on every call, so there is no default
  # issuer or JWKS URL: the receiver is disabled until an operator configures it.
  #
  #   JWT_SSO_ISSUER         expected `iss` claim (required)
  #   JWT_SSO_JWKS_URL       URL of the issuer's JWKS document (required)
  #   JWT_SSO_AUDIENCE       expected value of the audience claim (required)
  #   JWT_SSO_ALGORITHM      signature algorithm, ES256 (default), ES384, RS256 or RS384
  #   JWT_SSO_CLAIM_AUDIENCE audience claim name (default "aud")
  #   JWT_SSO_CLAIM_EMAIL    email claim name (default "email")
  #   JWT_SSO_CLAIM_NAME     display name claim (default "name")
  #   JWT_SSO_CLAIM_EMAIL_VERIFIED claim asserting the email is verified, default
  #                          "email_verified". An existing local user is signed in
  #                          by email ONLY when this claim is true; otherwise the
  #                          token is treated as having no usable email.
  #   JWT_SSO_MAX_AGE_SECONDS maximum token lifetime (exp - iat) and age, default
  #                          300, capped at 600. Also the replay-memory lifetime.
  #   JWT_SSO_CLAIM_TENANT   optional claim holding an external tenant id
  #   JWT_SSO_CLAIM_TIER     optional claim holding a plan/tier name
  #   JWT_SSO_ALLOWED_TIERS  optional comma separated tiers allowed to sign in;
  #                          when set, a token without an allowed tier is rejected
  module Config
    ALGORITHMS = %w[ES256 ES384 RS256 RS384].freeze

    module_function

    def issuer = env('JWT_SSO_ISSUER')

    def jwks_url = env('JWT_SSO_JWKS_URL')

    def audience = env('JWT_SSO_AUDIENCE')

    def algorithm
      value = env('JWT_SSO_ALGORITHM').upcase
      ALGORITHMS.include?(value) ? value : 'ES256'
    end

    def audience_claim = env('JWT_SSO_CLAIM_AUDIENCE', 'aud')

    def email_claim = env('JWT_SSO_CLAIM_EMAIL', 'email')

    def name_claim = env('JWT_SSO_CLAIM_NAME', 'name')

    def email_verified_claim = env('JWT_SSO_CLAIM_EMAIL_VERIFIED', 'email_verified')

    MAX_AGE_CAP = 600
    DEFAULT_MAX_AGE = 300

    def max_age
      value = env('JWT_SSO_MAX_AGE_SECONDS', DEFAULT_MAX_AGE.to_s).to_i
      value.positive? ? [value, MAX_AGE_CAP].min : DEFAULT_MAX_AGE
    end

    def tenant_claim = env('JWT_SSO_CLAIM_TENANT')

    def tier_claim = env('JWT_SSO_CLAIM_TIER')

    def allowed_tiers
      env('JWT_SSO_ALLOWED_TIERS').split(',').map(&:strip).reject(&:empty?)
    end

    def enabled?
      issuer.present? && jwks_url.present? && audience.present?
    end

    def env(name, default = '')
      value = ENV.fetch(name, nil).to_s.strip
      value.empty? ? default : value
    end
  end
end
