# frozen_string_literal: true

require 'rails_helper'

# A token with a made-up kid forces a refetch of the key set (a key rotation looks
# the same). A flood of made-up kids must not become a flood of requests to the issuer.
describe ServiceAuth::JwksClient do
  let(:url) { 'https://idp.example.test/jwks' }
  let(:client) { described_class.new(jwks_url: url, cache: ActiveSupport::Cache::MemoryStore.new) }

  before do
    stub_request(:get, url).to_return(status: 200, headers: { 'Content-Type' => 'application/json' },
                                      body: { keys: [{ kid: 'known', kty: 'EC' }] }.to_json)
  end

  it 'refetches for an unknown kid, but only a few times a minute' do
    20.times { |i| expect(client.find_key("made-up-#{i}")).to be_nil }

    # one fetch to fill the cache, then at most the allowed number of forced refetches
    limit = described_class::MAX_FORCED_REFETCHES_PER_MINUTE
    expect(a_request(:get, url)).to have_been_made.at_most_times(1 + limit)
  end

  it 'still serves a known kid from the cache while the refetch limit is used up' do
    10.times { |i| client.find_key("made-up-#{i}") }

    expect(client.find_key('known')).to include('kid' => 'known')
  end

  it 'still picks up a rotated key once the limit window has room' do
    client.find_key('known')
    stub_request(:get, url).to_return(status: 200, headers: { 'Content-Type' => 'application/json' },
                                      body: { keys: [{ kid: 'rotated', kty: 'EC' }] }.to_json)

    expect(client.find_key('rotated')).to include('kid' => 'rotated')
  end
end
