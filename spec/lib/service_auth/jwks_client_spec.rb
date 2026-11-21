# frozen_string_literal: true

require 'rails_helper'

# Unit coverage for ServiceAuth::JwksClient: fetching, caching, kid-miss refetch and failure mapping.
describe ServiceAuth::JwksClient do
  let(:url) { 'http://localhost:8090/.well-known/jwks.json' }

  before do
    @cache = ActiveSupport::Cache::MemoryStore.new
    @ec_key = OpenSSL::PKey::EC.generate('prime256v1')
    @kid = SecureRandom.uuid
    @jwk = JWT::JWK.new(@ec_key, kid: @kid, alg: 'ES256', use: 'sig')
  end

  it 'fetches + caches the JWKS on first call' do
    stub_request(:get, url).to_return(
      status: 200,
      body: { keys: [@jwk.export] }.to_json,
      headers: { 'Content-Type' => 'application/json' }
    )

    client = described_class.new(jwks_url: url, cache: @cache)
    found = client.find_key(@kid)
    expect(found).to be_present
    expect(found['kid']).to eq(@kid)

    # Second call hits the cache.
    second = client.find_key(@kid)
    expect(second).to be_present
    assert_requested :get, url, times: 1
  end

  it 'force-refetches once on a cache miss for an unknown kid' do
    other_kid = SecureRandom.uuid
    other_jwk = JWT::JWK.new(OpenSSL::PKey::EC.generate('prime256v1'),
                             kid: other_kid, alg: 'ES256', use: 'sig').export

    stub_request(:get, url).to_return(
      { status: 200, body: { keys: [other_jwk] }.to_json,
        headers: { 'Content-Type' => 'application/json' } },
      { status: 200, body: { keys: [other_jwk, @jwk.export] }.to_json,
        headers: { 'Content-Type' => 'application/json' } }
    )

    client = described_class.new(jwks_url: url, cache: @cache)
    expect(client.find_key(@kid)).to be_present
    assert_requested :get, url, times: 2
  end

  it 'raises JwksUnreachable on a 5xx response' do
    stub_request(:get, url).to_return(status: 503, body: 'down')

    client = described_class.new(jwks_url: url, cache: @cache)
    expect { client.find_key(@kid) }.to raise_error(ServiceAuth::JwksClient::JwksUnreachable)
  end

  it 'raises JwksUnreachable on a connection refused' do
    stub_request(:get, url).to_raise(Errno::ECONNREFUSED)

    client = described_class.new(jwks_url: url, cache: @cache)
    expect { client.find_key(@kid) }.to raise_error(ServiceAuth::JwksClient::JwksUnreachable)
  end

  it 'raises JwksMalformed on non-JSON response' do
    stub_request(:get, url).to_return(status: 200, body: 'not-json')

    client = described_class.new(jwks_url: url, cache: @cache)
    expect { client.find_key(@kid) }.to raise_error(ServiceAuth::JwksClient::JwksMalformed)
  end

  it 'returns nil for blank kid without hitting the network' do
    client = described_class.new(jwks_url: url, cache: @cache)
    expect(client.find_key('')).to be_nil
    expect(client.find_key(nil)).to be_nil
    assert_not_requested :get, url
  end
end
