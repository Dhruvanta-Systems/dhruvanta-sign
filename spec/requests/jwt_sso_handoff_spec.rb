# frozen_string_literal: true

require 'rails_helper'

# Request coverage for the generic JWT SSO receiver (GET /sso/handoff and
# POST /api/auth/sso-handoff):
#
#   1. happy verify + provision a new user
#   2. happy verify + look up an existing user
#   3. expired token, wrong audience, wrong issuer, tampered signature
#   4. unknown kid triggers a JWKS refetch
#   5. JWKS unreachable (5xx becomes a 503 problem body)
#   6. replayed jti (409)
#   7. tier allow-list
#   8. receiver disabled (404) when not configured
#
# A fresh ES256 keypair is generated in `before(:all)` and the JWKS endpoint is
# stubbed with WebMock.
describe 'JWT SSO handoff receiver' do
  let(:issuer) { 'https://idp.example.test' }
  let(:audience) { 'sign-app' }
  let(:jwks_url) { 'https://idp.example.test/.well-known/jwks.json' }

  before(:all) do
    @ec_key = OpenSSL::PKey::EC.generate('prime256v1')
    @kid    = SecureRandom.uuid
    @jwk    = JWT::JWK.new(@ec_key, kid: @kid, alg: 'ES256', use: 'sig')
  end

  before do
    stub_env('JWT_SSO_ISSUER' => issuer, 'JWT_SSO_JWKS_URL' => jwks_url, 'JWT_SSO_AUDIENCE' => audience,
             'JWT_SSO_CLAIM_TENANT' => 'tenantId', 'JWT_SSO_CLAIM_TIER' => 'tier',
             'JWT_SSO_ALLOWED_TIERS' => 'pro,enterprise')

    # Reset Rails.cache so the replay-defence in-memory store starts
    # empty for each example. DocuSeal's test environment uses
    # `:null_store` so `write(unless_exist: true)` always succeeds —
    # we swap to a per-example MemoryStore so the replay test can
    # observe the second-write rejection.
    @memory_cache = ActiveSupport::Cache::MemoryStore.new
    allow(Rails).to receive(:cache).and_return(@memory_cache)

    # Default JWKS stub: published `keys: [@jwk]`.
    stub_request(:get, jwks_url).to_return(
      status: 200,
      headers: { 'Content-Type' => 'application/json' },
      body: { keys: [@jwk.export] }.to_json
    )
  end

  def stub_env(values)
    @saved_env ||= {}
    values.each do |key, value|
      @saved_env[key] = ENV.fetch(key, nil) unless @saved_env.key?(key)
      ENV[key] = value
    end
  end

  after do
    (@saved_env || {}).each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def mint_token(claims_overrides = nil, signing_key: @ec_key, kid: @kid, **claim_keyword_overrides)
    now = Time.now.utc.to_i
    claims = {
      iss: issuer,
      sub: SecureRandom.uuid,
      tenantId: SecureRandom.uuid,
      aud: audience,
      tier: 'pro',
      email: 'sso-user@example.com',
      email_verified: true,
      name: 'Ada Lovelace',
      iat: now,
      exp: now + 30,
      jti: SecureRandom.uuid
    }.merge(claims_overrides || {}).merge(claim_keyword_overrides)

    JWT.encode(claims, signing_key, 'ES256', { kid: kid, typ: 'JWT' })
  end

  describe 'POST /api/auth/sso-handoff' do
    it 'verifies + auto-provisions a new DocuSeal user, sets session, returns 200' do
      expect(User.count).to eq(0)
      expect(Account.count).to eq(0)

      external_user_id = SecureRandom.uuid
      external_tenant_id = SecureRandom.uuid
      token = mint_token(sub: external_user_id, tenantId: external_tenant_id)

      post '/api/auth/sso-handoff', params: { token: token }, as: :json

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body['email']).to eq('sso-user@example.com')
      expect(body['user_id']).to be_present
      expect(body['tier']).to eq('pro')

      # Auto-provision: a fresh User + Account row landed.
      expect(User.count).to eq(1)
      expect(Account.count).to eq(1)
      user = User.last
      expect(user.email).to eq('sso-user@example.com')
      expect(user.first_name).to eq('Ada')
      expect(user.last_name).to eq('Lovelace')
      expect(user.user_configs.find_by(key: UserConfig::EXTERNAL_USER_ID_KEY).value)
        .to eq(external_user_id)
      expect(user.account.account_configs.find_by(key: AccountConfig::EXTERNAL_TENANT_ID_KEY).value)
        .to eq(external_tenant_id)
    end

    it 'verifies + looks up an existing DocuSeal user without re-provisioning' do
      account = create(:account)
      existing = create(:user, account: account, email: 'existing@example.com',
                               first_name: 'Pre', last_name: 'Existing')

      external_user_id = SecureRandom.uuid
      external_tenant_id = SecureRandom.uuid
      token = mint_token(email: 'existing@example.com', name: 'Pre Existing',
                         sub: external_user_id, tenantId: external_tenant_id)

      expect { post '/api/auth/sso-handoff', params: { token: token }, as: :json }
        .not_to(change { User.count })

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['user_id']).to eq(existing.uuid)
      expect(existing.reload.user_configs.find_by(key: UserConfig::EXTERNAL_USER_ID_KEY).value)
        .to eq(external_user_id)
      expect(account.account_configs.find_by(key: AccountConfig::EXTERNAL_TENANT_ID_KEY).value)
        .to eq(external_tenant_id)
    end

    it 'rejects an expired token with 401 and code sso-handoff-expired' do
      now = Time.now.utc.to_i
      token = mint_token(iat: now - 120, exp: now - 60)

      post '/api/auth/sso-handoff', params: { token: token }, as: :json

      expect(response).to have_http_status(:unauthorized)
      expect(response.media_type).to eq('application/problem+json')
      expect(response.parsed_body['code']).to eq('sso-handoff-expired')
    end

    it 'rejects a wrong audience with 403 and code sso-handoff-wrong-aud' do
      token = mint_token(aud: 'another-app')

      post '/api/auth/sso-handoff', params: { token: token }, as: :json

      expect(response).to have_http_status(:forbidden)
      expect(response.media_type).to eq('application/problem+json')
      expect(response.parsed_body['code']).to eq('sso-handoff-wrong-aud')
    end

    it 'rejects a tampered signature with 401 and code sso-handoff-signature-invalid' do
      foreign_key = OpenSSL::PKey::EC.generate('prime256v1')
      # Sign with a key whose kid IS in the JWKS, but the key bytes
      # differ — verification must fail closed.
      token = mint_token({}, signing_key: foreign_key, kid: @kid)

      post '/api/auth/sso-handoff', params: { token: token }, as: :json

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body['code']).to eq('sso-handoff-signature-invalid')
    end

    it 'force-refetches the JWKS when the token kid is unknown, then accepts on next fetch' do
      # First response: published JWKS without our kid. Second
      # response: published JWKS WITH our kid. The receiver must
      # transparently retry on the cache miss.
      stub_request(:get, jwks_url)
        .to_return(
          { status: 200, body: { keys: [] }.to_json,
            headers: { 'Content-Type' => 'application/json' } },
          { status: 200, body: { keys: [@jwk.export] }.to_json,
            headers: { 'Content-Type' => 'application/json' } }
        )

      token = mint_token

      post '/api/auth/sso-handoff', params: { token: token }, as: :json

      expect(response).to have_http_status(:ok)
      assert_requested :get, jwks_url, times: 2
    end

    it 'returns 503 sso-handoff-jwks-unreachable when the JWKS endpoint 5xxs' do
      stub_request(:get, jwks_url).to_return(status: 502, body: 'bad gateway')

      token = mint_token

      post '/api/auth/sso-handoff', params: { token: token }, as: :json

      expect(response).to have_http_status(:service_unavailable)
      expect(response.media_type).to eq('application/problem+json')
      expect(response.parsed_body['code']).to eq('sso-handoff-jwks-unreachable')
    end

    it 'rejects a replayed jti within the replay window with 409 sso-handoff-jti-replayed' do
      token = mint_token(jti: 'replayed-jti')

      post '/api/auth/sso-handoff', params: { token: token }, as: :json
      expect(response).to have_http_status(:ok)

      post '/api/auth/sso-handoff', params: { token: token }, as: :json
      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body['code']).to eq('sso-handoff-jti-replayed')
    end

    it 'does not sign in as an existing user when the email is not asserted as verified' do
      existing = create(:user, account: create(:account), email: 'existing@example.com')
      token = mint_token(email: 'existing@example.com', email_verified: false, sub: 'attacker-sub')

      post '/api/auth/sso-handoff', params: { token: token }, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['user_id']).not_to eq(existing.uuid)
      expect(response.parsed_body['email']).to eq('sso-attacker-sub@sso-handoff.invalid')
    end

    it 'rejects a token that stays valid longer than the maximum lifetime' do
      now = Time.now.utc.to_i
      token = mint_token(iat: now, exp: now + 86_400)

      post '/api/auth/sso-handoff', params: { token: token }, as: :json

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body['code']).to eq('sso-handoff-lifetime-too-long')
    end

    it 'rejects a long-lived token replayed after the old 90 second window' do
      now = Time.now.utc.to_i
      token = mint_token(iat: now, exp: now + 290, jti: 'long-lived')
      post '/api/auth/sso-handoff', params: { token: token }, as: :json
      expect(response).to have_http_status(:ok)

      travel_to(200.seconds.from_now) do
        post '/api/auth/sso-handoff', params: { token: token }, as: :json
      end

      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body['code']).to eq('sso-handoff-jti-replayed')
    end

    it 'rejects a token with the wrong issuer with 401 sso-handoff-wrong-issuer' do
      token = mint_token(iss: 'https://attacker.example/')

      post '/api/auth/sso-handoff', params: { token: token }, as: :json

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body['code']).to eq('sso-handoff-wrong-issuer')
    end

    it 'rejects an empty token with 401 sso-handoff-missing' do
      post '/api/auth/sso-handoff', params: { token: '' }, as: :json

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body['code']).to eq('sso-handoff-missing')
    end

    it 'rejects a tier outside the allow-list with 403 and code sso-handoff-tier-not-allowed' do
      token = mint_token(tier: 'free')

      post '/api/auth/sso-handoff', params: { token: token }, as: :json

      expect(response).to have_http_status(:forbidden)
      expect(response.media_type).to eq('application/problem+json')
      expect(response.parsed_body['code']).to eq('sso-handoff-tier-not-allowed')
    end

    it 'rejects a token without a tier when an allow-list is configured' do
      claims = { iss: issuer, sub: SecureRandom.uuid, aud: audience, email: 'a@example.com',
                 iat: Time.now.utc.to_i, exp: Time.now.utc.to_i + 30, jti: SecureRandom.uuid }
      token = JWT.encode(claims, @ec_key, 'ES256', { kid: @kid, typ: 'JWT' })

      post '/api/auth/sso-handoff', params: { token: token }, as: :json

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body['code']).to eq('sso-handoff-tier-not-allowed')
    end

    it 'answers 404 when the receiver is not configured' do
      stub_env('JWT_SSO_ISSUER' => '')

      post '/api/auth/sso-handoff', params: { token: mint_token }, as: :json

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body['code']).to eq('sso-handoff-not-configured')
    end
  end

  describe 'GET /sso/handoff' do
    it 'verifies + signs the user in + redirects to root on success' do
      token = mint_token

      get '/sso/handoff', params: { token: token }

      expect(response).to redirect_to('/')
      expect(User.last.email).to eq('sso-user@example.com')
    end

    it 'redirects to /sign_in?reason=sso-failed&code=... on verify-stage failure' do
      now = Time.now.utc.to_i
      token = mint_token(iat: now - 120, exp: now - 60)

      get '/sso/handoff', params: { token: token }

      expect(response).to be_redirect
      expect(response.location).to include('reason=sso-failed')
      expect(response.location).to include('code=sso-handoff-expired')
    end
  end
end
