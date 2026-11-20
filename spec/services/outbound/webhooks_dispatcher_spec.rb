# frozen_string_literal: true

require 'rails_helper'

# Coverage for Outbound::WebhooksDispatcher: enqueue, delivery id derivation and HTTP dispatch with retries.
RSpec.describe Outbound::WebhooksDispatcher do
  let(:outbox_url) { 'http://receiver.test/webhooks' }
  let(:secret) { 'test-secret' }

  before do
    ENV['WEBHOOK_OUTBOX_URL'] = outbox_url
    ENV['WEBHOOK_OUTBOX_SECRET'] = secret
    # Skip backoff sleeps so the spec stays fast.
    allow(described_class).to receive(:sleep)
  end

  after do
    ENV.delete('WEBHOOK_OUTBOX_URL')
    ENV.delete('WEBHOOK_OUTBOX_SECRET')
  end

  def build_row(payload: '{"a":1}',
                event_type: WebhookOutbox::EVENT_SUBMISSION_CREATED,
                delivery_id: SecureRandom.uuid)
    WebhookOutbox.new(
      target: WebhookOutbox::TARGET_DEFAULT,
      event_type: event_type,
      payload: payload,
      delivery_id: delivery_id,
      status: WebhookOutbox::STATUS_PENDING,
      attempts: 0,
      created_at: Time.current
    )
  end

  def stub_responses(*statuses)
    counter = { i: 0 }
    allow(described_class).to receive(:perform_request) do |_url, _body, _sig, _did|
      idx = counter[:i]
      counter[:i] += 1
      status = statuses[idx] || statuses.last
      raise Faraday::TimeoutError, 'timeout' if status == :timeout

      double('Response', status: status)
    end
  end

  describe '.dispatch' do
    it 'returns success on a 200 first attempt' do
      stub_responses(200)
      result = described_class.dispatch(build_row)

      expect(result).to be_success
      expect(result.http_status).to eq(200)
    end

    it 'retries on 429 and succeeds on the second attempt' do
      stub_responses(429, 200)
      result = described_class.dispatch(build_row)

      expect(result).to be_success
      expect(result.http_status).to eq(200)
    end

    it 'fails when 429 retries exhaust the budget' do
      stub_responses(429, 429, 429)
      result = described_class.dispatch(build_row)

      expect(result).not_to be_success
      expect(result.http_status).to eq(429)
      expect(result.error).to start_with('transient:')
    end

    it 'fails on three 5xx responses (transient exhausted)' do
      stub_responses(500, 503, 502)
      result = described_class.dispatch(build_row)

      expect(result).not_to be_success
      expect(result.error).to start_with('transient:')
    end

    it 'recovers from a transient timeout on retry' do
      stub_responses(:timeout, 200)
      result = described_class.dispatch(build_row)

      expect(result).to be_success
    end

    it 'sends exactly the three locked headers on the wire' do
      captured = {}
      allow(described_class).to receive(:perform_request) do |url, body, sig, did|
        captured[:url] = url
        captured[:body] = body
        captured[:signature] = sig
        captured[:delivery_id] = did
        double('Response', status: 200)
      end
      row = build_row(payload: '{"x":42}')
      described_class.dispatch(row)

      expect(captured[:url]).to eq(outbox_url)
      expect(captured[:body]).to eq('{"x":42}')
      expect(captured[:signature]).to match(/\A[0-9a-f]{64}\z/)
      expect(captured[:delivery_id]).to eq(row.delivery_id)
    end

    it 'fails immediately on a non-retryable 4xx (no retry)' do
      counter = { i: 0 }
      allow(described_class).to receive(:perform_request) do |_, _, _, _|
        counter[:i] += 1
        double('Response', status: 400)
      end
      result = described_class.dispatch(build_row)

      expect(result).not_to be_success
      expect(result.error).to start_with('non-retryable:')
      expect(counter[:i]).to eq(1)
    end

    it 'fails when WEBHOOK_OUTBOX_URL is unset' do
      ENV.delete('WEBHOOK_OUTBOX_URL')
      result = described_class.dispatch(build_row)

      expect(result).not_to be_success
      expect(result.error).to include('WEBHOOK_OUTBOX_URL')
    end

    it 'fails when WEBHOOK_OUTBOX_SECRET is unset' do
      ENV.delete('WEBHOOK_OUTBOX_SECRET')
      result = described_class.dispatch(build_row)

      expect(result).not_to be_success
      expect(result.error).to include('WEBHOOK_OUTBOX_SECRET')
    end
  end

  describe '.compute_delivery_id' do
    it 'is deterministic for the same (target, event_type, key) tuple' do
      a = described_class.compute_delivery_id('default', 'submission_created', 'sub-1')
      b = described_class.compute_delivery_id('default', 'submission_created', 'sub-1')
      expect(a).to eq(b)
    end

    it 'differs across distinct keys' do
      a = described_class.compute_delivery_id('default', 'submission_created', 'sub-1')
      b = described_class.compute_delivery_id('default', 'submission_created', 'sub-2')
      expect(a).not_to eq(b)
    end

    it 'returns a UUID-shaped value' do
      uuid = described_class.compute_delivery_id('default', 'submission_completed', 'sub-99')
      expect(uuid).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/)
    end

    it 'falls back to a random UUID when the idempotency key is blank' do
      a = described_class.compute_delivery_id('aud', 'evt', '')
      b = described_class.compute_delivery_id('aud', 'evt', '')
      expect(a).not_to eq(b)
    end
  end

  describe '.enqueue' do
    it 'creates a pending outbox row and returns the deterministic delivery_id' do
      payload = { 'submission_id' => 42 }
      delivery_id = described_class.enqueue(
        WebhookOutbox::TARGET_DEFAULT,
        WebhookOutbox::EVENT_SUBMISSION_CREATED,
        payload,
        'submission:42:created'
      )
      row = WebhookOutbox.find_by(delivery_id: delivery_id)

      expect(row).not_to be_nil
      expect(row).to be_pending
      expect(row.attempts).to eq(0)
      expect(row.event_type).to eq('submission_created')
      expect(JSON.parse(row.payload)['submission_id']).to eq(42)
    end

    it 'is idempotent — re-enqueue with the same idempotency key returns the same delivery_id (no second row)' do
      first  = described_class.enqueue(WebhookOutbox::TARGET_DEFAULT,
                                       WebhookOutbox::EVENT_SUBMITTER_SIGNED,
                                       { 'submitter_id' => 7 },
                                       'submitter:7')
      second = described_class.enqueue(WebhookOutbox::TARGET_DEFAULT,
                                       WebhookOutbox::EVENT_SUBMITTER_SIGNED,
                                       { 'submitter_id' => 7 },
                                       'submitter:7')

      expect(first).to eq(second)
      expect(WebhookOutbox.where(delivery_id: first).count).to eq(1)
    end

    it 'returns nil and does NOT raise when args are blank' do
      expect(described_class.enqueue('', 'submission_created', '{}', 'k')).to be_nil
      expect(described_class.enqueue(WebhookOutbox::TARGET_DEFAULT, '', '{}', 'k')).to be_nil
      expect(described_class.enqueue(WebhookOutbox::TARGET_DEFAULT, 'submission_created', nil, 'k')).to be_nil
    end
  end
end
