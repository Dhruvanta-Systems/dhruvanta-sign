# frozen_string_literal: true

require 'rails_helper'
require 'base64'
require 'json'

# Coverage for Outbound::OauthTokenClient: minting, caching, refresh, retries and secret validation.
#
# Sleep is stubbed so the retry path stays fast. The test environment uses
# `:null_store`, so assertions about caching swap in a MemoryStore.
RSpec.describe Outbound::OauthTokenClient do
  let(:token_url) { 'http://auth.test/oauth/token' }
  let(:full_url) { token_url }
  let(:client_id)     { 'docuseal-outbound-test' }
  let(:secret_value)  { 'top-secret-123' }
  let(:secret_path)   { Tempfile.create(['client-secret', '.txt']).path.tap { |p| File.write(p, secret_value) } }
  let(:cache) { ActiveSupport::Cache::MemoryStore.new }
  let(:audience) { 'api.example.test' }

  before do
    ENV['OAUTH_TOKEN_URL'] = token_url
    ENV['OAUTH_CLIENT_ID'] = client_id
    ENV['OAUTH_CLIENT_SECRET_PATH'] = secret_path
    ENV['OAUTH_TOKEN_REFRESH_BEFORE_SECONDS'] = '60'
    ENV['OAUTH_TOKEN_MAX_ATTEMPTS'] = '3'
    allow(described_class).to receive(:sleep)
  end

  after do
    ENV.delete('OAUTH_TOKEN_URL')
    ENV.delete('OAUTH_CLIENT_ID')
    ENV.delete('OAUTH_CLIENT_SECRET_PATH')
    ENV.delete('OAUTH_TOKEN_REFRESH_BEFORE_SECONDS')
    ENV.delete('OAUTH_TOKEN_MAX_ATTEMPTS')
    File.delete(secret_path) if File.exist?(secret_path)
  end

  def fake_jwt_with_jti(jti)
    header = Base64.urlsafe_encode64('{"alg":"ES256","kid":"k1"}', padding: false)
    payload = Base64.urlsafe_encode64(JSON.generate(jti: jti, sub: 'docuseal'), padding: false)
    "#{header}.#{payload}.signature"
  end

  def stub_http(*responses)
    @request_bodies = []
    counter = { i: 0 }
    fake_http = double('Faraday')
    allow(fake_http).to receive(:post) do |_url, &block|
      req = Struct.new(:headers, :options, :body).new({}, Struct.new(:timeout, :open_timeout).new, nil)
      block&.call(req)
      @request_bodies << req.body
      idx = counter[:i]
      counter[:i] += 1
      resp = responses[idx] || responses.last
      raise Faraday::TimeoutError, 'timeout' if resp.is_a?(Symbol) && resp == :timeout

      double('Response', status: resp[:status], body: resp[:body])
    end
    fake_http
  end

  describe '#access_token' do
    it 'mints a fresh token on cache miss' do
      http = stub_http(status: 200,
                       body: JSON.generate(access_token: fake_jwt_with_jti('jti-1'), expires_in: 900))
      subject = described_class.new(cache: cache, http: http)

      token = subject.access_token(audience)

      expect(token).to start_with('eyJ')
      expect(http).to have_received(:post).once
      cached_raw = cache.read("outbound:oauth_token:#{audience}")
      expect(cached_raw).not_to be_nil
    end

    it 'returns the cached token without a wire request on cache hit' do
      http = stub_http(status: 200,
                       body: JSON.generate(access_token: fake_jwt_with_jti('jti-2'), expires_in: 900))
      subject = described_class.new(cache: cache, http: http)

      first  = subject.access_token(audience)
      second = subject.access_token(audience)

      expect(first).to eq(second)
      expect(http).to have_received(:post).once
    end

    it 'refreshes when the cached token is within the refresh window' do
      first_token  = fake_jwt_with_jti('jti-old')
      second_token = fake_jwt_with_jti('jti-new')
      # First mint with a TINY expires_in so the second call sees near-expiry.
      http = stub_http(
        { status: 200, body: JSON.generate(access_token: first_token, expires_in: 30) },
        { status: 200, body: JSON.generate(access_token: second_token, expires_in: 900) }
      )
      subject = described_class.new(cache: cache, http: http)

      first  = subject.access_token(audience)
      second = subject.access_token(audience)

      expect(first).to eq(first_token)
      expect(second).to eq(second_token)
      expect(http).to have_received(:post).twice
    end

    it 'retries on 429 and succeeds on a later attempt' do
      http = stub_http(
        { status: 429, body: '{"error":"too_many"}' },
        { status: 200, body: JSON.generate(access_token: fake_jwt_with_jti('jti-r'), expires_in: 900) }
      )
      allow_any_instance_of(described_class).to receive(:sleep)
      subject = described_class.new(cache: cache, http: http)

      token = subject.access_token(audience)

      expect(token).to be_a(String)
      expect(http).to have_received(:post).twice
    end

    it 'fails closed on a non-retryable 4xx (no retry)' do
      http = stub_http(status: 400, body: '{"error":"invalid_request"}')
      allow_any_instance_of(described_class).to receive(:sleep)
      subject = described_class.new(cache: cache, http: http)

      expect { subject.access_token(audience) }
        .to raise_error(described_class::TokenError, /HTTP 400/)
      expect(http).to have_received(:post).once
    end

    it 'raises when OAUTH_TOKEN_URL is unset' do
      ENV.delete('OAUTH_TOKEN_URL')
      subject = described_class.new(cache: cache, http: double('Faraday'))

      expect { subject.access_token(audience) }
        .to raise_error(described_class::TokenError, /OAUTH_TOKEN_URL/)
    end

    it 'raises when the secret file is missing' do
      ENV['OAUTH_CLIENT_SECRET_PATH'] = '/tmp/does-not-exist-missing'
      subject = described_class.new(cache: cache, http: double('Faraday'))

      expect { subject.access_token(audience) }
        .to raise_error(described_class::TokenError, /secret file not found/)
    end

    it 'raises when the secret file is empty' do
      empty_path = Tempfile.create(['client-secret-empty', '.txt']).path
      File.write(empty_path, '')
      ENV['OAUTH_CLIENT_SECRET_PATH'] = empty_path
      begin
        subject = described_class.new(cache: cache, http: double('Faraday'))

        expect { subject.access_token(audience) }
          .to raise_error(described_class::TokenError, /empty/)
      ensure
        File.delete(empty_path) if File.exist?(empty_path)
      end
    end

    it 'omits audience and scope from the request when they are not configured' do
      http = stub_http(status: 200, body: JSON.generate(access_token: fake_jwt_with_jti('jti-9'), expires_in: 900))
      subject = described_class.new(cache: cache, http: http)

      subject.access_token('')

      expect(@request_bodies.last).not_to include('audience=')
      expect(@request_bodies.last).not_to include('scope=')
    end

    it 'sends scope when OAUTH_SCOPE is set' do
      ENV['OAUTH_SCOPE'] = 'mail.send'
      http = stub_http(status: 200, body: JSON.generate(access_token: fake_jwt_with_jti('jti-8'), expires_in: 900))
      subject = described_class.new(cache: cache, http: http)

      subject.access_token(audience)

      expect(@request_bodies.last).to include('scope=mail.send')
      expect(@request_bodies.last).to include('audience=api.example.test')
    ensure
      ENV.delete('OAUTH_SCOPE')
    end

    it 'raises on malformed JSON response' do
      http = stub_http(status: 200, body: 'not-json')
      subject = described_class.new(cache: cache, http: http)

      expect { subject.access_token(audience) }
        .to raise_error(described_class::TokenError, /malformed JSON/)
    end

    it 'raises on response missing access_token' do
      http = stub_http(status: 200, body: JSON.generate(expires_in: 900))
      subject = described_class.new(cache: cache, http: http)

      expect { subject.access_token(audience) }
        .to raise_error(described_class::TokenError, /access_token/)
    end

    it 'emits an audit log line on MISS with structured JSON' do
      http = stub_http(status: 200,
                       body: JSON.generate(access_token: fake_jwt_with_jti('jti-audit'), expires_in: 900))
      logger = double('Logger', info: nil, warn: nil)
      subject = described_class.new(cache: cache, http: http, logger: logger)

      subject.access_token(audience)

      expect(logger).to have_received(:info).with(a_string_starting_with('audit.oauth_token '))
    end
  end
end
