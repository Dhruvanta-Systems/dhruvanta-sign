# frozen_string_literal: true

require 'rails_helper'

# Unit coverage for JwtSso::HandoffService#verify_handoff and
# #lookup_or_provision_user: claim mapping, the optional tier allow-list and the
# not-configured guard.
describe JwtSso::HandoffService do
  let(:issuer) { 'https://idp.example.test' }
  let(:audience) { 'sign-app' }
  let(:nonce) { 'browser-state-1' }
  let(:jwks_url) { 'http://localhost:8090/.well-known/jwks.json' }

  before(:all) do
    @ec_key = OpenSSL::PKey::EC.generate('prime256v1')
    @kid    = SecureRandom.uuid
    @jwk    = JWT::JWK.new(@ec_key, kid: @kid, alg: 'ES256', use: 'sig')
  end

  before do
    @saved_env = {}
    {
      'JWT_SSO_ISSUER' => issuer, 'JWT_SSO_JWKS_URL' => jwks_url, 'JWT_SSO_AUDIENCE' => audience,
      'JWT_SSO_CLAIM_TENANT' => 'tenantId', 'JWT_SSO_CLAIM_TIER' => 'tier'
    }.each do |key, value|
      @saved_env[key] = ENV.fetch(key, nil)
      ENV[key] = value
    end

    # The test environment uses `:null_store`, where `write(unless_exist: true)`
    # always succeeds; use a per-example MemoryStore so jti capture works.
    @memory_cache = ActiveSupport::Cache::MemoryStore.new
    allow(Rails).to receive(:cache).and_return(@memory_cache)

    stub_request(:get, jwks_url).to_return(
      status: 200,
      headers: { 'Content-Type' => 'application/json' },
      body: { keys: [@jwk.export] }.to_json
    )
  end

  after do
    @saved_env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def verify(token)
    build_service.verify_handoff(token, expected_nonce: nonce)
  end

  def build_service
    described_class.new(
      jwks_client: JwtSso::JwksClient.new(jwks_url: jwks_url, cache: @memory_cache)
    )
  end

  def encode(claims)
    JWT.encode(claims, @ec_key, 'ES256', { kid: @kid, typ: 'JWT' })
  end

  def base_claims
    now = Time.now.utc.to_i
    {
      iss: issuer, sub: SecureRandom.uuid, tenantId: SecureRandom.uuid, aud: audience,
      email: 'sso-user@example.com', email_verified: true, name: 'Ada Lovelace', tier: 'pro',
      iat: now, exp: now + 30, jti: SecureRandom.uuid, nonce: nonce
    }
  end

  def mint_token(**overrides)
    encode(base_claims.merge(overrides))
  end

  describe '#verify_handoff claim mapping' do
    it 'maps subject, tenant, email, name and tier onto the VerifiedHandoff struct' do
      verified = verify(mint_token(sub: 'user-1', tenantId: 'tenant-1', tier: 'enterprise'))

      expect(verified.subject).to eq('user-1')
      expect(verified.tenant_id).to eq('tenant-1')
      expect(verified.email).to eq('sso-user@example.com')
      expect(verified.display_name).to eq('Ada Lovelace')
      expect(verified.tier).to eq('enterprise')
    end

    it 'accepts an audience array that contains the configured audience' do
      verified = verify(mint_token(aud: ['other', audience]))

      expect(verified.audience).to eq(['other', audience])
    end

    it 'honours renamed claims' do
      ENV['JWT_SSO_CLAIM_EMAIL'] = 'mail'
      ENV['JWT_SSO_CLAIM_NAME'] = 'full_name'
      verified = verify(mint_token(mail: 'renamed@example.com', full_name: 'Grace Hopper'))

      expect(verified.email).to eq('renamed@example.com')
      expect(verified.display_name).to eq('Grace Hopper')
    ensure
      ENV.delete('JWT_SSO_CLAIM_EMAIL')
      ENV.delete('JWT_SSO_CLAIM_NAME')
    end

    it 'leaves tier and tenant nil when their claims are not configured' do
      ENV.delete('JWT_SSO_CLAIM_TENANT')
      ENV.delete('JWT_SSO_CLAIM_TIER')

      verified = verify(mint_token)

      expect(verified.tenant_id).to be_nil
      expect(verified.tier).to be_nil
    end
  end

  describe '#verify_handoff browser binding' do
    it 'rejects a token whose nonce is not the browser state' do
      expect { build_service.verify_handoff(mint_token, expected_nonce: 'other') }
        .to raise_error(JwtSso::HandoffService::HandoffError) { |e| expect(e.code).to eq('sso-handoff-nonce-mismatch') }
    end

    it 'rejects a token with no nonce claim' do
      expect { verify(mint_token(nonce: nil)) }
        .to raise_error(JwtSso::HandoffService::HandoffError) { |e| expect(e.code).to eq('sso-handoff-nonce-mismatch') }
    end

    it 'refuses to verify at all without a browser state' do
      expect { build_service.verify_handoff(mint_token, expected_nonce: '') }
        .to raise_error(JwtSso::HandoffService::HandoffError) { |e| expect(e.code).to eq('sso-handoff-state-missing') }
    end
  end

  describe '#verify_handoff tier allow-list' do
    before { ENV['JWT_SSO_ALLOWED_TIERS'] = 'pro, enterprise' }

    after { ENV.delete('JWT_SSO_ALLOWED_TIERS') }

    it 'accepts a tier in the allow-list' do
      expect(verify(mint_token(tier: 'enterprise')).tier).to eq('enterprise')
    end

    it 'raises TierNotAllowedError on a tier outside the allow-list' do
      expect { verify(mint_token(tier: 'free')) }
        .to raise_error(JwtSso::HandoffService::TierNotAllowedError) { |e|
          expect(e.code).to eq('sso-handoff-tier-not-allowed')
          expect(e.http_status).to eq(:forbidden)
          expect(e.tier).to eq('free')
        }
    end

    it 'raises TierNotAllowedError when the token carries no tier at all' do
      claims = base_claims.except(:tier)

      expect { verify(encode(claims)) }
        .to raise_error(JwtSso::HandoffService::TierNotAllowedError) { |e| expect(e.tier).to be_nil }
    end
  end

  describe '#verify_handoff replay and lifetime' do
    it 'rejects the same token used twice' do
      token = mint_token
      verify(token)

      expect { verify(token) }
        .to raise_error(JwtSso::HandoffService::HandoffError) { |e| expect(e.code).to eq('sso-handoff-jti-replayed') }
    end

    it 'remembers the jti for the whole maximum lifetime plus clock skew' do
      allow(@memory_cache).to receive(:write).and_call_original

      verify(mint_token)

      expect(@memory_cache).to have_received(:write)
        .with(a_string_starting_with('sso_handoff_jti:'), anything, hash_including(expires_in: 330.seconds, unless_exist: true))
    end

    it 'honours a shorter JWT_SSO_MAX_AGE_SECONDS for the replay memory' do
      ENV['JWT_SSO_MAX_AGE_SECONDS'] = '60'
      allow(@memory_cache).to receive(:write).and_call_original

      verify(mint_token)

      expect(@memory_cache).to have_received(:write).with(anything, anything, hash_including(expires_in: 90.seconds))
    ensure
      ENV.delete('JWT_SSO_MAX_AGE_SECONDS')
    end

    it 'rejects a token whose lifetime exceeds the maximum' do
      now = Time.now.utc.to_i

      expect { verify(mint_token(iat: now, exp: now + 3600)) }
        .to raise_error(JwtSso::HandoffService::HandoffError) { |e| expect(e.code).to eq('sso-handoff-lifetime-too-long') }
    end

    it 'caps the configured maximum at 10 minutes' do
      ENV['JWT_SSO_MAX_AGE_SECONDS'] = '86400'
      now = Time.now.utc.to_i

      expect { verify(mint_token(iat: now, exp: now + 3600)) }
        .to raise_error(JwtSso::HandoffService::HandoffError) { |e| expect(e.code).to eq('sso-handoff-lifetime-too-long') }
    ensure
      ENV.delete('JWT_SSO_MAX_AGE_SECONDS')
    end

    it 'rejects a token issued longer ago than the maximum even if exp is still ahead' do
      now = Time.now.utc.to_i

      expect { verify(mint_token(iat: now - 400, exp: now + 100)) }
        .to raise_error(JwtSso::HandoffService::HandoffError) { |e| expect(e.code).to eq('sso-handoff-too-old') }
    end

    it 'rejects a token without iat' do
      expect { verify(encode(base_claims.except(:iat))) }
        .to raise_error(JwtSso::HandoffService::HandoffError) { |e| expect(e.code).to eq('sso-handoff-missing-iat') }
    end

    it 'fails closed when the cache does not retain writes' do
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::NullStore.new)
      service = described_class.new(jwks_client: JwtSso::JwksClient.new(jwks_url: jwks_url, cache: @memory_cache),
                                    cache: ActiveSupport::Cache::NullStore.new)

      expect { service.verify_handoff(mint_token, expected_nonce: nonce) }
        .to raise_error(JwtSso::HandoffService::HandoffError) { |e|
          expect(e.code).to eq('sso-handoff-replay-store-unavailable')
          expect(e.http_status).to eq(:service_unavailable)
        }
    end
  end

  describe 'when not configured' do
    it 'raises NotConfiguredError without fetching the JWKS' do
      ENV['JWT_SSO_ISSUER'] = ''

      expect { verify(mint_token) }
        .to raise_error(JwtSso::HandoffService::NotConfiguredError) { |e|
          expect(e.code).to eq('sso-handoff-not-configured')
          expect(e.http_status).to eq(:not_found)
        }
      expect(a_request(:get, jwks_url)).not_to have_been_made
    end
  end

  describe '#lookup_or_provision_user' do
    let!(:existing) { create(:user, email: 'victim@example.com') }

    it 'links to an existing user by email when the token asserts a verified email' do
      verified = verify(mint_token(email: 'victim@example.com', email_verified: true))

      expect(build_service.lookup_or_provision_user(verified)).to eq(existing)
    end

    it 'accepts the string "true" as a verified email' do
      verified = verify(mint_token(email: 'victim@example.com', email_verified: 'true'))

      expect(build_service.lookup_or_provision_user(verified)).to eq(existing)
    end

    [false, nil, 'false', 'yes'].each do |value|
      it "never links to an existing user when email_verified is #{value.inspect}" do
        token = encode(base_claims.merge(email: 'victim@example.com', email_verified: value, sub: 'attacker-sub-1'))
        verified = verify(token)

        user = build_service.lookup_or_provision_user(verified)

        expect(user).not_to eq(existing)
        expect(user.email).to eq('sso-attacker-sub-1@sso-handoff.invalid')
        expect(existing.reload.account_id).not_to eq(user.account_id)
      end
    end

    it 'never links when the verified claim is absent' do
      token = encode(base_claims.except(:email_verified).merge(email: 'victim@example.com', sub: 'attacker-sub-2'))

      user = build_service.lookup_or_provision_user(verify(token))

      expect(user).not_to eq(existing)
    end

    it 'honours a renamed verified-email claim' do
      ENV['JWT_SSO_CLAIM_EMAIL_VERIFIED'] = 'mail_ok'
      token = encode(base_claims.except(:email_verified).merge(email: 'victim@example.com', mail_ok: true))

      expect(build_service.lookup_or_provision_user(verify(token))).to eq(existing)
    ensure
      ENV.delete('JWT_SSO_CLAIM_EMAIL_VERIFIED')
    end

    it 'uses a synthetic non-routable address when the token has no email' do
      verified = verify(mint_token(email: nil, email_verified: nil, sub: 'abcdef123456'))

      user = build_service.lookup_or_provision_user(verified)

      expect(user.email).to eq('sso-abcdef123456@sso-handoff.invalid')
    end
  end
end
