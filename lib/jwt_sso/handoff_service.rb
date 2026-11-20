# frozen_string_literal: true

require 'jwt'
require 'openssl'
require 'base64'

module JwtSso
  # Verifies a signed JWT issued by a configured identity provider and signs the
  # matching user in, creating the user (inside a fresh account) on first sight.
  #
  # Verification (see {JwtSso::Config} for the settings):
  #
  #   * the signature is checked against the key published in the issuer's JWKS,
  #     selected by the token's `kid` header
  #   * `iss` must equal the configured issuer
  #   * the audience claim must equal the configured audience
  #   * `iat` and `exp` are required; `exp` must be in the future, `iat` no more
  #     than 30 seconds ahead and no older than JWT_SSO_MAX_AGE_SECONDS, and the
  #     lifetime (`exp - iat`) no longer than that maximum (default 5 minutes)
  #   * the nonce claim (JWT_SSO_CLAIM_NONCE, default `nonce`) must equal the
  #     state stored in the visitor's own cookie, so the token is bound to the
  #     browser that started the flow
  #   * `jti` must not have been seen before. It is remembered for the full
  #     maximum lifetime, so an accepted token can never be replayed while it is
  #     still valid. The store is `Rails.cache`; behind several app servers it
  #     must be a shared store, and a cache that does not retain writes (such as
  #     the null store) makes the handoff fail closed with a 503.
  #   * an existing local user is matched by email only when the token asserts a
  #     verified email (JWT_SSO_CLAIM_EMAIL_VERIFIED, default `email_verified`)
  #   * when allowed tiers are configured, the tier claim must be one of them
  #
  # A user that already exists locally and has two-factor authentication enabled
  # skips the OTP prompt after a successful SSO sign-in: the identity provider
  # is trusted to have authenticated the person.
  class HandoffService
    class HandoffError < StandardError
      attr_reader :code, :http_status

      def initialize(code, http_status = :unauthorized)
        super(code)
        @code = code
        @http_status = http_status
      end
    end

    class TierNotAllowedError < HandoffError
      attr_reader :tier

      def initialize(tier)
        super('sso-handoff-tier-not-allowed', :forbidden)
        @tier = tier
      end
    end

    class NotConfiguredError < HandoffError
      def initialize
        super('sso-handoff-not-configured', :not_found)
      end
    end

    MAX_CLOCK_SKEW = 30 # seconds

    VerifiedHandoff = Struct.new(
      :jti, :subject, :tenant_id, :audience, :email, :email_verified, :display_name, :tier, :expires_at,
      keyword_init: true
    )

    def initialize(jwks_client: nil, audit_emitter: nil, cache: Rails.cache)
      @jwks_client = jwks_client || JwtSso::JwksClient.new
      @audit_emitter = audit_emitter || JwtSso::AuditEmitter.new
      @cache = cache
    end

    # @return [VerifiedHandoff]
    # @raise [HandoffError] with a machine readable code on any failure
    def verify_handoff(token, expected_nonce:)
      raise NotConfiguredError unless JwtSso::Config.enabled?
      raise HandoffError.new('sso-handoff-missing', :unauthorized) if blank?(token)

      _payload, header = decode_unverified(token)
      kid = header['kid']

      raise HandoffError.new('sso-handoff-wrong-alg', :unauthorized) unless header['alg'] == JwtSso::Config.algorithm
      raise HandoffError.new('sso-handoff-missing-kid', :unauthorized) if blank?(kid)

      jwk = lookup_jwk(kid)
      raise HandoffError.new('sso-handoff-unknown-kid', :unauthorized) if jwk.nil?

      claims = decode_verified(token, jwk)[0]

      validate_issuer!(claims)
      validate_audience!(claims)
      validate_exp!(claims)
      validate_iat!(claims)
      validate_nonce!(claims, expected_nonce)
      jti = validate_and_capture_jti!(claims)
      tier = validate_tier!(claims)

      VerifiedHandoff.new(
        jti: jti,
        subject: claims['sub'],
        tenant_id: claim_value(claims, JwtSso::Config.tenant_claim),
        audience: claims[JwtSso::Config.audience_claim],
        email: claims[JwtSso::Config.email_claim],
        email_verified: verified_claim?(claims[JwtSso::Config.email_verified_claim]),
        display_name: claims[JwtSso::Config.name_claim],
        tier: tier,
        expires_at: Time.at(claims['exp']).utc
      )
    end

    # Finds the local user for the verified handoff or provisions one.
    #
    # With a usable email claim that the token asserts is verified, the user is
    # looked up (or created) by that address. Otherwise a synthetic, non-routable
    # address derived from the subject is used, so the same person always maps to
    # the same user and an unverified email can never take over another account.
    #
    # @return [User]
    def lookup_or_provision_user(handoff)
      effective_email =
        if handoff.email_verified && handoff.email.present? && looks_like_email?(handoff.email)
          handoff.email.downcase
        else
          "sso-#{handoff.subject}@sso-handoff.invalid"
        end

      effective_display = handoff.display_name.presence || default_display(handoff.subject)
      first_name, last_name = split_display_name(effective_display)

      user = User.find_by(email: effective_email)
      if user
        persist_external_scope!(handoff, user)
        return user
      end

      # The account and user are created in one transaction so a failed
      # `User.create!` never leaves an orphan account behind.
      user = ActiveRecord::Base.transaction do
        account = Account.create!(
          name: effective_display.presence || effective_email.split('@').first,
          locale: 'en-US',
          timezone: 'UTC'
        )

        User.create!(
          account: account,
          email: effective_email,
          first_name: first_name,
          last_name: last_name,
          password: SecureRandom.hex(32),
          role: User::ADMIN_ROLE
        )
      end

      persist_external_scope!(handoff, user)
      user
    end

    def audit_received(handoff, user, ip:, user_agent:)
      @audit_emitter.sso_received(
        actor_user_id: user&.id,
        jti: handoff.jti,
        external_user_id: handoff.subject,
        external_tenant_id: handoff.tenant_id,
        tier: handoff.tier,
        ip: ip,
        user_agent: user_agent
      )
    end

    def audit_failed(failure_reason, jti: nil, ip: nil, user_agent: nil)
      @audit_emitter.sso_failed(
        failure_reason: failure_reason,
        jti: jti,
        ip: ip,
        user_agent: user_agent
      )
    end

    private

    def decode_unverified(token)
      JWT.decode(token, nil, false)
    rescue JWT::DecodeError
      raise HandoffError.new('sso-handoff-malformed', :unauthorized)
    end

    def lookup_jwk(kid)
      @jwks_client.find_key(kid)
    rescue JwtSso::JwksClient::JwksUnreachable => e
      Rails.logger.warn("sso-handoff-jwks-unreachable kid=#{kid} reason=#{e.message}")
      raise HandoffError.new('sso-handoff-jwks-unreachable', :service_unavailable)
    rescue JwtSso::JwksClient::JwksMalformed => e
      Rails.logger.warn("sso-handoff-jwks-malformed kid=#{kid} reason=#{e.message}")
      raise HandoffError.new('sso-handoff-jwks-malformed', :service_unavailable)
    end

    def decode_verified(token, jwk)
      jwk_obj = JWT::JWK.new(jwk)
      JWT.decode(token, jwk_obj.public_key, true, algorithm: JwtSso::Config.algorithm)
    rescue JWT::ExpiredSignature
      raise HandoffError.new('sso-handoff-expired', :unauthorized)
    rescue JWT::IncorrectAlgorithm
      raise HandoffError.new('sso-handoff-wrong-alg', :unauthorized)
    rescue JWT::VerificationError, JWT::DecodeError
      raise HandoffError.new('sso-handoff-signature-invalid', :unauthorized)
    end

    def validate_issuer!(claims)
      return if claims['iss'] == JwtSso::Config.issuer

      raise HandoffError.new('sso-handoff-wrong-issuer', :unauthorized)
    end

    def validate_audience!(claims)
      value = claims[JwtSso::Config.audience_claim]
      audiences = value.is_a?(Array) ? value : [value]
      return if audiences.include?(JwtSso::Config.audience)

      raise HandoffError.new('sso-handoff-wrong-aud', :forbidden)
    end

    def validate_exp!(claims)
      exp = claims['exp']
      raise HandoffError.new('sso-handoff-expired', :unauthorized) if exp.nil?
      raise HandoffError.new('sso-handoff-expired', :unauthorized) if Time.at(exp).utc < Time.now.utc
    end

    def validate_iat!(claims)
      iat = claims['iat']
      raise HandoffError.new('sso-handoff-missing-iat', :unauthorized) unless iat.is_a?(Numeric)

      now = Time.now.utc
      raise HandoffError.new('sso-handoff-future-iat', :unauthorized) if Time.at(iat).utc > now + MAX_CLOCK_SKEW

      max_age = JwtSso::Config.max_age
      raise HandoffError.new('sso-handoff-too-old', :unauthorized) if Time.at(iat).utc < now - max_age
      raise HandoffError.new('sso-handoff-lifetime-too-long', :unauthorized) if claims['exp'] - iat > max_age
    end

    # The token must be minted for THIS browser: it has to carry the nonce that
    # {JwtSsoHandoffController#start} put in the visitor's cookie. A token
    # obtained by someone else therefore cannot sign a victim's browser in.
    def validate_nonce!(claims, expected_nonce)
      raise HandoffError.new('sso-handoff-state-missing', :unauthorized) if blank?(expected_nonce)

      actual = claims[JwtSso::Config.nonce_claim].to_s
      return if !actual.empty? && ActiveSupport::SecurityUtils.secure_compare(actual, expected_nonce.to_s)

      raise HandoffError.new('sso-handoff-nonce-mismatch', :unauthorized)
    end

    def replay_ttl
      JwtSso::Config.max_age + MAX_CLOCK_SKEW
    end

    def validate_and_capture_jti!(claims)
      jti = claims['jti']
      raise HandoffError.new('sso-handoff-missing-jti', :unauthorized) if blank?(jti)

      # `unless_exist: true` makes the write atomic, so a second use of the same
      # jti inside the replay window is detected. The window outlives the token's
      # maximum validity, so replay is impossible while the token is still valid.
      key = "sso_handoff_jti:#{jti}"
      claimed = @cache.write(key, Time.now.utc.iso8601, expires_in: replay_ttl, unless_exist: true)
      raise HandoffError.new('sso-handoff-jti-replayed', :conflict) unless claimed

      # A cache that silently drops writes (the null store) would make replay
      # protection a no-op, so refuse to continue.
      raise HandoffError.new('sso-handoff-replay-store-unavailable', :service_unavailable) unless @cache.exist?(key)

      jti
    end

    # Only enforced when JWT_SSO_ALLOWED_TIERS is configured.
    def validate_tier!(claims)
      allowed = JwtSso::Config.allowed_tiers
      tier = claim_value(claims, JwtSso::Config.tier_claim)
      return tier if allowed.empty?

      raise TierNotAllowedError, tier unless allowed.include?(tier)

      tier
    end

    def verified_claim?(value)
      value == true || value.to_s.downcase == 'true'
    end

    def claim_value(claims, name)
      return nil if blank?(name)

      value = claims[name]
      blank?(value) ? nil : value.to_s
    end

    def looks_like_email?(value)
      at = value.index('@')
      return false if at.nil? || at <= 0 || at == value.length - 1

      domain = value[(at + 1)..]
      domain.include?('.') && !domain.start_with?('.') && !domain.end_with?('.')
    end

    def default_display(subject)
      slug = subject.to_s
      "SSO user #{slug.length >= 8 ? slug[0...8] : slug}"
    end

    def split_display_name(display)
      parts = display.to_s.strip.split(/\s+/, 2)
      [parts[0], parts[1]]
    end

    def blank?(value)
      value.nil? || value.to_s.empty?
    end

    def persist_external_scope!(handoff, user)
      JwtSso::ScopeStore.persist!(
        account: user&.account,
        user: user,
        tenant_id: handoff&.tenant_id,
        external_user_id: handoff&.subject
      )
    rescue StandardError => e
      Rails.logger.warn(
        "sso-handoff-scope-persist-failed user_id=#{user&.id} reason=#{e.class.name}: #{e.message}"
      )
    end
  end
end
