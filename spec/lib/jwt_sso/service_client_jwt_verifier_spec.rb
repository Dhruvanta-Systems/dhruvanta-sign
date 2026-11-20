# frozen_string_literal: true

require 'rails_helper'

# Coverage for JwtSso::ServiceClientJwtVerifier: audience, scope, expiry and JWKS failure handling.
describe JwtSso::ServiceClientJwtVerifier do
  let(:jwks_url) { 'http://localhost:8081/.well-known/jwks.json' }
  let(:expected_audience) { 'audit.sign.example.test' }
  let(:required_scope) { 'audit.read' }

  before(:all) do
    @ec_key = OpenSSL::PKey::EC.generate('prime256v1')
    @kid    = SecureRandom.uuid
    @jwk    = JWT::JWK.new(@ec_key, kid: @kid, alg: 'ES256', use: 'sig')
  end

  before do
    @cache = ActiveSupport::Cache::MemoryStore.new
    stub_request(:get, jwks_url).to_return(
      status: 200,
      headers: { 'Content-Type' => 'application/json' },
      body: { keys: [@jwk.export] }.to_json
    )
  end

  def build_verifier
    jwks = JwtSso::JwksClient.new(jwks_url: jwks_url, cache: @cache)
    described_class.new(jwks_client: jwks,
                        expected_audience: expected_audience,
                        required_scope: required_scope)
  end

  def mint(claims_overrides = {}, signing_key: @ec_key, kid: @kid, **extra_claims)
    now = Time.now.utc.to_i
    claims_overrides = claims_overrides.merge(extra_claims)
    claims = {
      iss: 'https://issuer.example.test',
      sub: 'svc-audit-reader',
      aud: expected_audience,
      scopes: required_scope,
      account_id: 42,
      iat: now,
      exp: now + 60,
      jti: SecureRandom.uuid
    }.merge(claims_overrides)

    JWT.encode(claims, signing_key, 'ES256', { kid: kid, typ: 'JWT' })
  end

  it 'returns a Verified struct on a happy fetch' do
    token = mint

    verified = build_verifier.verify(token)

    expect(verified.audience).to eq(expected_audience)
    expect(verified.scopes).to include(required_scope)
    expect(verified.subject).to eq('svc-audit-reader')
    expect(verified.expires_at).to be > Time.now.utc
  end

  it 'rejects an expired token with service-token-expired' do
    token = mint(iat: Time.now.utc.to_i - 120, exp: Time.now.utc.to_i - 60)

    expect { build_verifier.verify(token) }
      .to raise_error(described_class::VerificationError) { |e|
        expect(e.code).to eq('service-token-expired')
        expect(e.http_status).to eq(:unauthorized)
      }
  end

  it 'returns the account the token is limited to' do
    expect(build_verifier.verify(mint).account_id).to eq(42)
  end

  it 'rejects a token without an account claim with service-token-no-account-scope' do
    expect { build_verifier.verify(mint(account_id: nil)) }
      .to raise_error(described_class::VerificationError) { |e|
        expect(e.code).to eq('service-token-no-account-scope')
        expect(e.http_status).to eq(:forbidden)
      }
  end

  it 'rejects a wrong issuer when an issuer is configured' do
    verifier = described_class.new(jwks_client: JwtSso::JwksClient.new(jwks_url: jwks_url, cache: @cache),
                                   expected_audience: expected_audience, required_scope: required_scope,
                                   expected_issuer: 'https://other.example.test')

    expect { verifier.verify(mint) }
      .to raise_error(described_class::VerificationError) { |e| expect(e.code).to eq('service-token-wrong-issuer') }
  end

  it 'rejects a wrong audience with service-token-wrong-aud' do
    token = mint(aud: 'audit.other.example.test')

    expect { build_verifier.verify(token) }
      .to raise_error(described_class::VerificationError) { |e|
        expect(e.code).to eq('service-token-wrong-aud')
        expect(e.http_status).to eq(:forbidden)
      }
  end

  it 'rejects a token missing the required scope with service-token-insufficient-scope' do
    token = mint(scopes: 'template.read')

    expect { build_verifier.verify(token) }
      .to raise_error(described_class::VerificationError) { |e|
        expect(e.code).to eq('service-token-insufficient-scope')
        expect(e.http_status).to eq(:forbidden)
      }
  end

  it 'force-refetches JWKS once on a kid cache miss' do
    other_kid = SecureRandom.uuid
    other_jwk = JWT::JWK.new(OpenSSL::PKey::EC.generate('prime256v1'),
                             kid: other_kid, alg: 'ES256', use: 'sig').export

    # First fetch: only the OTHER kid is published. Cache miss for our
    # @kid forces a second fetch which now includes both keys.
    stub_request(:get, jwks_url).to_return(
      { status: 200, body: { keys: [other_jwk] }.to_json,
        headers: { 'Content-Type' => 'application/json' } },
      { status: 200, body: { keys: [other_jwk, @jwk.export] }.to_json,
        headers: { 'Content-Type' => 'application/json' } }
    )

    token = mint
    verified = build_verifier.verify(token)
    expect(verified.audience).to eq(expected_audience)
    assert_requested :get, jwks_url, times: 2
  end

  it 'maps JWKS unreachable to service-jwks-unreachable / 503' do
    stub_request(:get, jwks_url).to_return(status: 503, body: 'down')

    token = mint
    expect { build_verifier.verify(token) }
      .to raise_error(described_class::VerificationError) { |e|
        expect(e.code).to eq('service-jwks-unreachable')
        expect(e.http_status).to eq(:service_unavailable)
      }
  end

  it 'rejects a malformed token with service-token-malformed' do
    expect { build_verifier.verify('not.a.valid-jwt') }
      .to raise_error(described_class::VerificationError) { |e|
        expect(e.code).to eq('service-token-malformed')
      }
  end

  it 'rejects a missing token with service-token-missing' do
    expect { build_verifier.verify(nil) }
      .to raise_error(described_class::VerificationError) { |e|
        expect(e.code).to eq('service-token-missing')
      }
    expect { build_verifier.verify('') }
      .to raise_error(described_class::VerificationError) { |e|
        expect(e.code).to eq('service-token-missing')
      }
  end
end

describe JwtSso::ServiceClientJwtVerifier, 'when not configured' do
  it 'answers 503 service-token-not-configured without any audience or scope' do
    verifier = described_class.new(jwks_client: JwtSso::JwksClient.new(jwks_url: ''), expected_audience: '',
                                   required_scope: '')

    expect { verifier.verify('anything') }.to raise_error(described_class::VerificationError) { |e|
      expect(e.code).to eq('service-token-not-configured')
      expect(e.http_status).to eq(:service_unavailable)
    }
  end
end
