# frozen_string_literal: true

require 'jwt'
require 'openssl'

# Verifies bearer JWTs presented by other services (machine to machine), as
# opposed to a person signing in (see Oidc).
#
# The token must be signed by a key in the JWKS at SERVICE_JWT_JWKS_URL, carry
# the expected audience and include the required scope in its `scopes` (array) or
# `scope` (space separated) claim. There is no sign-in side effect; the verifier
# returns a struct the controller uses to authorise the request.
#
# Every failure raises {VerificationError} with a machine readable code and an
# HTTP status (401, 403 or 503).
#
#   SERVICE_JWT_JWKS_URL    JWKS of the token issuer (required)
#   SERVICE_JWT_AUDIENCE    expected audience (required)
#   SERVICE_JWT_AUDIT_SCOPE scope required by the audit endpoint (default "audit.read")
#   SERVICE_JWT_ISSUER      expected `iss` claim; checked only when set
#   SERVICE_JWT_ACCOUNT_CLAIM claim naming the one account the token may read
#                           (default "account_id"). A token without it is refused:
#                           there is no token that reads every account.
module ServiceAuth
  class ServiceClientJwtVerifier
    class VerificationError < StandardError
      attr_reader :code, :http_status

      def initialize(code, http_status = :unauthorized)
        super(code)
        @code = code
        @http_status = http_status
      end
    end

    MAX_CLOCK_SKEW = 30 # seconds

    Verified = Struct.new(:audience, :scopes, :subject, :jti, :expires_at, :account_id, keyword_init: true)

    def self.default_audience
      ENV.fetch('SERVICE_JWT_AUDIENCE', '').strip
    end

    def self.default_audit_scope
      ENV.fetch('SERVICE_JWT_AUDIT_SCOPE', 'audit.read').strip
    end

    def self.default_issuer
      ENV.fetch('SERVICE_JWT_ISSUER', '').strip
    end

    def self.account_claim
      value = ENV.fetch('SERVICE_JWT_ACCOUNT_CLAIM', '').strip
      value.empty? ? 'account_id' : value
    end

    def initialize(jwks_client: nil, expected_audience: self.class.default_audience,
                   required_scope: self.class.default_audit_scope, expected_issuer: self.class.default_issuer,
                   account_claim: self.class.account_claim)
      @jwks_client = jwks_client || build_default_jwks_client
      @expected_audience = expected_audience
      @required_scope = required_scope
      @expected_issuer = expected_issuer
      @account_claim = account_claim
    end

    # Verify a bearer token and assert audience + scope.
    #
    # @param token [String] raw bearer (no "Bearer " prefix)
    # @return [Verified]
    # @raise [VerificationError] on any failure
    def verify(token)
      raise VerificationError.new('service-token-not-configured', :service_unavailable) if not_configured?
      raise VerificationError.new('service-token-missing', :unauthorized) if blank?(token)

      _payload, header = decode_unverified(token)
      kid = header['kid']
      alg = header['alg']

      raise VerificationError.new('service-token-wrong-alg', :unauthorized) unless alg == 'ES256'
      raise VerificationError.new('service-token-missing-kid', :unauthorized) if blank?(kid)

      jwk = lookup_jwk(kid)
      raise VerificationError.new('service-token-unknown-kid', :unauthorized) if jwk.nil?

      decoded = decode_verified(token, jwk)
      claims = decoded[0]

      validate_issuer!(claims)
      validate_audience!(claims)
      validate_scope!(claims)
      account_id = extract_account_id!(claims)
      validate_exp!(claims)
      validate_iat!(claims)

      Verified.new(
        audience: claims['aud'],
        scopes: extract_scopes(claims),
        subject: claims['sub'],
        jti: claims['jti'],
        expires_at: Time.at(claims['exp']).utc,
        account_id: account_id
      )
    end

    private

    def not_configured?
      blank?(@expected_audience) || blank?(@required_scope) || blank?(@jwks_client.jwks_url)
    end

    def build_default_jwks_client
      ServiceAuth::JwksClient.new(jwks_url: ENV.fetch('SERVICE_JWT_JWKS_URL', '').strip)
    end

    def decode_unverified(token)
      JWT.decode(token, nil, false)
    rescue JWT::DecodeError
      raise VerificationError.new('service-token-malformed', :unauthorized)
    end

    def lookup_jwk(kid)
      @jwks_client.find_key(kid)
    rescue ServiceAuth::JwksClient::JwksUnreachable => e
      Rails.logger.warn("service-jwks-unreachable kid=#{kid} reason=#{e.message}")
      raise VerificationError.new('service-jwks-unreachable', :service_unavailable)
    rescue ServiceAuth::JwksClient::JwksMalformed => e
      Rails.logger.warn("service-jwks-malformed kid=#{kid} reason=#{e.message}")
      raise VerificationError.new('service-jwks-malformed', :service_unavailable)
    end

    def decode_verified(token, jwk)
      jwk_obj = JWT::JWK.new(jwk)
      JWT.decode(token, jwk_obj.public_key, true, algorithm: 'ES256')
    rescue JWT::ExpiredSignature
      raise VerificationError.new('service-token-expired', :unauthorized)
    rescue JWT::IncorrectAlgorithm
      raise VerificationError.new('service-token-wrong-alg', :unauthorized)
    rescue JWT::VerificationError, JWT::DecodeError
      raise VerificationError.new('service-token-signature-invalid', :unauthorized)
    end

    def validate_issuer!(claims)
      return if blank?(@expected_issuer)
      return if claims['iss'] == @expected_issuer

      raise VerificationError.new('service-token-wrong-issuer', :unauthorized)
    end

    # The export is scoped to exactly one account, named by the token. A token
    # that names none is refused rather than treated as "all accounts".
    def extract_account_id!(claims)
      raw = claims[@account_claim]
      raise VerificationError.new('service-token-no-account-scope', :forbidden) unless raw.to_s.match?(/\A\d{1,18}\z/)

      raw.to_s.to_i
    end

    def validate_audience!(claims)
      aud = claims['aud']
      # `aud` may be a single string or an array per RFC 7519 §4.1.3.
      audiences = aud.is_a?(Array) ? aud : [aud]
      return if audiences.include?(@expected_audience)

      raise VerificationError.new('service-token-wrong-aud', :forbidden)
    end

    def validate_scope!(claims)
      scopes = extract_scopes(claims)
      return if scopes.include?(@required_scope)

      raise VerificationError.new('service-token-insufficient-scope', :forbidden)
    end

    def validate_exp!(claims)
      exp = claims['exp']
      raise VerificationError.new('service-token-expired', :unauthorized) if exp.nil?
      raise VerificationError.new('service-token-expired', :unauthorized) if Time.at(exp).utc < Time.now.utc
    end

    def validate_iat!(claims)
      iat = claims['iat']
      return if iat.nil?

      now = Time.now.utc
      raise VerificationError.new('service-token-future-iat', :unauthorized) if Time.at(iat).utc > now + MAX_CLOCK_SKEW
    end

    # `scopes` arrives as either a space-delimited string (OAuth 2.0
    # convention per RFC 6749 §3.3) or a JSON array. Accept both.
    def extract_scopes(claims)
      raw = claims['scopes'] || claims['scope']
      return [] if raw.nil?
      return raw if raw.is_a?(Array)

      raw.to_s.split(/\s+/).reject(&:empty?)
    end

    def blank?(value)
      value.nil? || value.to_s.empty?
    end
  end
end
