# frozen_string_literal: true

module Oidc
  # Verifies a JWS issued by the provider: the signature against the provider's keys
  # with an algorithm from an allow-list (never `none`, never an HMAC, so a token
  # signed with a public key as if it were a secret is refused), then the common
  # claims. The id_token and the logout_token each add their own checks.
  module TokenVerifier
    module_function

    # @return [Hash] the claims (indifferent access)
    # @raise [Oidc::Error]
    def verify_signature(jwt, typ: nil)
      header = decode_header(jwt)
      alg = header['alg'].to_s

      raise Error, 'invalid_token_alg' unless Config.allowed_algs.include?(alg)
      raise Error, 'invalid_token_type' if typ && header['typ'].to_s.casecmp(typ).nonzero?

      key = Jwks.key_for(header['kid'].to_s)
      raise Error, 'unknown_token_key' unless key

      JSON::JWT.decode(jwt, key, [alg.to_sym]).with_indifferent_access
    rescue JSON::JWT::Exception, JSON::JWS::Exception, JSON::JWK::Set::KidNotFound, ArgumentError, OpenSSL::OpenSSLError
      raise Error, 'invalid_token_signature'
    end

    def decode_header(jwt)
      segment = jwt.to_s.split('.', 3).first.to_s
      header = JSON.parse(Base64.urlsafe_decode64(segment))
      raise Error, 'invalid_token' unless header.is_a?(Hash)

      header
    rescue JSON::ParserError, ArgumentError
      raise Error, 'invalid_token'
    end

    def audiences(claims)
      Array(claims['aud']).map(&:to_s)
    end

    def check_issuer_and_audience!(claims)
      raise Error, 'issuer_mismatch' unless claims['iss'].to_s == Config.issuer

      audiences = audiences(claims)
      raise Error, 'audience_mismatch' unless audiences.include?(Config.client_id)
      raise Error, 'authorized_party_mismatch' if audiences.size > 1 && claims['azp'].to_s != Config.client_id
      raise Error, 'authorized_party_mismatch' if claims['azp'].present? && claims['azp'].to_s != Config.client_id
    end

    def check_times!(claims, max_age: Config.max_id_token_age)
      now = Time.now.to_i
      exp = claims['exp']
      iat = claims['iat']

      raise Error, 'token_expired' unless exp.is_a?(Numeric) && exp + Config::CLOCK_SKEW > now
      raise Error, 'token_issued_in_the_future' unless iat.is_a?(Numeric) && iat <= now + Config::CLOCK_SKEW
      raise Error, 'token_too_old' if now - iat > max_age + Config::CLOCK_SKEW
    end
  end
end
