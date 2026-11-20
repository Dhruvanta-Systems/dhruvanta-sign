# frozen_string_literal: true

require 'rails_helper'
require 'json'

# Coverage for Outbound::HttpMailApiClient: request shape, retries, error mapping and audit logging.
#
# Sleep is stubbed so the spec stays fast.
RSpec.describe Outbound::HttpMailApiClient do
  let(:base_url) { 'http://mail-api.test' }
  let(:full_url) { "#{base_url}/email" }
  let(:fake_token) { 'jwt-test-token' }
  let(:token_client) do
    instance_double(Outbound::OauthTokenClient).tap do |tc|
      allow(tc).to receive(:access_token).and_return(fake_token)
    end
  end

  before do
    ENV['MAIL_API_BASE_URL'] = base_url
    ENV['MAIL_API_MAX_ATTEMPTS'] = '3'
    allow(described_class).to receive(:sleep)
  end

  after do
    ENV.delete('MAIL_API_BASE_URL')
    ENV.delete('MAIL_API_MAX_ATTEMPTS')
  end

  def stub_http(*responses)
    captured = []
    counter = { i: 0 }
    fake_http = double('Faraday')
    allow(fake_http).to receive(:post) do |url, &block|
      idx = counter[:i]
      counter[:i] += 1
      resp = responses[idx] || responses.last
      raise Faraday::TimeoutError, 'timeout' if resp.is_a?(Symbol) && resp == :timeout

      # Capture the request envelope (build a fake req object).
      req = Struct.new(:headers, :options, :body).new({}, Struct.new(:timeout, :open_timeout).new(nil, nil), nil)
      block&.call(req)
      captured << { url: url, headers: req.headers, body: req.body }

      double('Response',
             status: resp[:status],
             body: resp[:body],
             headers: resp[:headers] || {})
    end
    [fake_http, captured]
  end

  def ok_body(delivery_id: 'd-123', status: 'queued', queued_at: '2026-05-07T12:00:00Z')
    JSON.generate(deliveryId: delivery_id, status: status, queuedAt: queued_at)
  end

  describe '#send' do
    it 'returns a DeliveryReceipt on a 200 response (happy path)' do
      http, captured = stub_http(status: 200, body: ok_body)
      subject = described_class.new(token_client: token_client, http: http)

      receipt = subject.send(
        template_key: 'user_invitation',
        recipient: 'jane@example.com',
        variables: { 'name' => 'Jane' },
        tenant_id: 'tenant-1',
        user_id: 'u-1',
        idempotency_key: 'idem-key-1'
      )

      expect(receipt).to be_a(described_class::DeliveryReceipt)
      expect(receipt.delivery_id).to eq('d-123')
      expect(receipt.status).to eq('queued')
      expect(receipt).to be_success
      expect(captured.first[:url]).to eq(full_url)
      expect(captured.first[:headers]['Authorization']).to eq("Bearer #{fake_token}")
      parsed = JSON.parse(captured.first[:body])
      expect(parsed['templateKey']).to eq('user_invitation')
      expect(parsed['recipient']).to eq('jane@example.com')
      expect(parsed['variables']).to eq('name' => 'Jane')
      expect(parsed['tenantId']).to eq('tenant-1')
      expect(parsed['userId']).to eq('u-1')
      expect(parsed['idempotencyKey']).to eq('idem-key-1')
    end

    it 'retries on 429 and succeeds on the second attempt' do
      http, = stub_http(
        { status: 429, body: '{"error":"too_many"}' },
        { status: 200, body: ok_body }
      )
      allow_any_instance_of(described_class).to receive(:sleep)
      subject = described_class.new(token_client: token_client, http: http)

      receipt = subject.send(template_key: 'user_invitation',
                             recipient: 'a@b.test',
                             tenant_id: 't-1',
                             idempotency_key: 'k1')

      expect(receipt).to be_success
    end

    it 'fails when 429 retries exhaust the budget' do
      http, = stub_http({ status: 429, body: '{}' },
                        { status: 429, body: '{}' },
                        { status: 429, body: '{}' })
      allow_any_instance_of(described_class).to receive(:sleep)
      subject = described_class.new(token_client: token_client, http: http)

      expect do
        subject.send(template_key: 'user_invitation',
                     recipient: 'a@b.test', tenant_id: 't-1', idempotency_key: 'k1')
      end.to raise_error(described_class::EmailDeliveryError, /retries exhausted/)
    end

    it 'fails on three 5xx responses (transient exhausted)' do
      http, = stub_http({ status: 500, body: '' },
                        { status: 503, body: '' },
                        { status: 502, body: '' })
      allow_any_instance_of(described_class).to receive(:sleep)
      subject = described_class.new(token_client: token_client, http: http)

      expect do
        subject.send(template_key: 'user_invitation',
                     recipient: 'a@b.test', tenant_id: 't-1', idempotency_key: 'k1')
      end.to raise_error(described_class::EmailDeliveryError, /retries exhausted/)
    end

    it 'recovers from a transient timeout on retry' do
      http, = stub_http(:timeout, { status: 200, body: ok_body })
      allow_any_instance_of(described_class).to receive(:sleep)
      subject = described_class.new(token_client: token_client, http: http)

      receipt = subject.send(template_key: 'user_invitation',
                             recipient: 'a@b.test', tenant_id: 't-1', idempotency_key: 'k1')

      expect(receipt).to be_success
    end

    it 'fails immediately on a non-retryable 4xx (no retry, RFC-7807 message extracted)' do
      problem_body = JSON.generate(
        type: 'https://mail-api.test/errors/invalid-template',
        title: 'Invalid template key',
        detail: 'unknown is not a registered template'
      )
      http, = stub_http(
        status: 400,
        body: problem_body,
        headers: { 'Content-Type' => 'application/problem+json' }
      )
      allow_any_instance_of(described_class).to receive(:sleep)
      subject = described_class.new(token_client: token_client, http: http)

      expect do
        subject.send(template_key: 'unknown',
                     recipient: 'a@b.test', tenant_id: 't-1', idempotency_key: 'k1')
      end.to raise_error(described_class::EmailDeliveryError, /Invalid template key.*not a registered template/)
    end

    it 'raises on malformed JSON response' do
      http, = stub_http(status: 200, body: 'not-json')
      subject = described_class.new(token_client: token_client, http: http)

      expect do
        subject.send(template_key: 'user_invitation',
                     recipient: 'a@b.test', tenant_id: 't-1', idempotency_key: 'k1')
      end.to raise_error(described_class::EmailDeliveryError, /malformed JSON/)
    end

    it 'raises on response missing deliveryId' do
      http, = stub_http(status: 200, body: JSON.generate(status: 'queued'))
      subject = described_class.new(token_client: token_client, http: http)

      expect do
        subject.send(template_key: 'user_invitation',
                     recipient: 'a@b.test', tenant_id: 't-1', idempotency_key: 'k1')
      end.to raise_error(described_class::EmailDeliveryError, /deliveryId/)
    end

    it 'emits a structured audit log on success' do
      http, = stub_http(status: 200, body: ok_body)
      logger = double('Logger', info: nil, warn: nil)
      subject = described_class.new(token_client: token_client, http: http, logger: logger)

      subject.send(template_key: 'user_invitation',
                   recipient: 'a@b.test', tenant_id: 't-1', idempotency_key: 'k1')

      expect(logger).to have_received(:info).with(a_string_starting_with('audit.mail_api_email '))
    end

    it 'fails closed on missing MAIL_API_BASE_URL' do
      ENV.delete('MAIL_API_BASE_URL')
      http, = stub_http(status: 200, body: ok_body)
      subject = described_class.new(token_client: token_client, http: http)

      expect do
        subject.send(template_key: 'user_invitation',
                     recipient: 'a@b.test', tenant_id: 't-1', idempotency_key: 'k1')
      end.to raise_error(described_class::EmailDeliveryError, /MAIL_API_BASE_URL/)
    end

    it 'rejects blank inputs' do
      http, = stub_http(status: 200, body: ok_body)
      subject = described_class.new(token_client: token_client, http: http)

      expect do
        subject.send(template_key: '', recipient: 'a@b.test', tenant_id: 't-1', idempotency_key: 'k1')
      end.to raise_error(described_class::EmailDeliveryError, /template_key/)

      expect do
        subject.send(template_key: 'tx/x', recipient: '', tenant_id: 't-1', idempotency_key: 'k1')
      end.to raise_error(described_class::EmailDeliveryError, /recipient/)

      expect do
        subject.send(template_key: 'tx/x', recipient: 'a@b', tenant_id: '', idempotency_key: 'k1')
      end.to raise_error(described_class::EmailDeliveryError, /tenant_id/)
    end
  end
end
