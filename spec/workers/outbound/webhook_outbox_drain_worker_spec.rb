# frozen_string_literal: true

require 'rails_helper'

# Coverage for Outbound::WebhookOutboxDrainWorker: batch drain, status transitions and re-scheduling.
RSpec.describe Outbound::WebhookOutboxDrainWorker do
  subject(:worker) { described_class.new }

  def make_row(status: WebhookOutbox::STATUS_PENDING,
               attempts: 0,
               event_type: WebhookOutbox::EVENT_SUBMISSION_CREATED)
    WebhookOutbox.create!(
      target_aud: WebhookOutbox::TARGET_DEFAULT,
      event_type: event_type,
      payload: '{"hello":"world"}',
      delivery_id: SecureRandom.uuid,
      status: status,
      attempts: attempts,
      created_at: Time.current
    )
  end

  describe '#run_once' do
    it 'flips a pending row to sent on a 2xx dispatch' do
      row = make_row
      allow(Outbound::WebhooksDispatcher).to receive(:dispatch)
        .and_return(Outbound::WebhooksDispatcher::DispatchResult.ok(200))

      processed = worker.run_once
      row.reload

      expect(processed).to eq(1)
      expect(row).to be_sent
      expect(row.attempts).to eq(1)
      expect(row.sent_at).not_to be_nil
      expect(row.last_error).to be_nil
    end

    it 'increments attempts and stays pending on a transient failure with retry budget remaining' do
      row = make_row
      allow(Outbound::WebhooksDispatcher).to receive(:dispatch)
        .and_return(Outbound::WebhooksDispatcher::DispatchResult.fail('transient: 500', 500))

      processed = worker.run_once
      row.reload

      expect(processed).to eq(0)
      expect(row).to be_pending
      expect(row.attempts).to eq(1)
      expect(row.last_error).to eq('transient: 500')
    end

    it 'flips to failed when attempts reach the retry-budget cap' do
      row = make_row(attempts: Outbound::WebhooksDispatcher::MAX_DISPATCH_ATTEMPTS - 1)
      allow(Outbound::WebhooksDispatcher).to receive(:dispatch)
        .and_return(Outbound::WebhooksDispatcher::DispatchResult.fail('transient: 500', 500))

      processed = worker.run_once
      row.reload

      expect(processed).to eq(1)
      expect(row).to be_failed
      expect(row.attempts).to eq(Outbound::WebhooksDispatcher::MAX_DISPATCH_ATTEMPTS)
    end

    it 'flips to failed immediately on a non-retryable 4xx' do
      row = make_row
      allow(Outbound::WebhooksDispatcher).to receive(:dispatch)
        .and_return(Outbound::WebhooksDispatcher::DispatchResult.fail('non-retryable: 400', 400))

      processed = worker.run_once
      row.reload

      expect(processed).to eq(1)
      expect(row).to be_failed
      expect(row.attempts).to eq(1)
    end

    it 'is idempotent on re-run — already-sent rows are not reprocessed' do
      row = make_row
      allow(Outbound::WebhooksDispatcher).to receive(:dispatch)
        .and_return(Outbound::WebhooksDispatcher::DispatchResult.ok(200))

      worker.run_once
      # On the second tick the row is already 'sent' — the pending
      # scope filter excludes it, so dispatch is NOT called a second
      # time.
      expect(Outbound::WebhooksDispatcher).to have_received(:dispatch).once
      worker.run_once
      expect(Outbound::WebhooksDispatcher).to have_received(:dispatch).once
      expect(row.reload).to be_sent
    end

    it 'drains multiple pending rows in one tick' do
      a = make_row
      b = make_row(event_type: WebhookOutbox::EVENT_SUBMITTER_SIGNED)
      allow(Outbound::WebhooksDispatcher).to receive(:dispatch)
        .and_return(Outbound::WebhooksDispatcher::DispatchResult.ok(200))

      processed = worker.run_once

      expect(processed).to eq(2)
      expect(a.reload).to be_sent
      expect(b.reload).to be_sent
    end
  end

  describe '#perform' do
    it 'self-reschedules another tick by default' do
      allow(Outbound::WebhooksDispatcher).to receive(:dispatch)
        .and_return(Outbound::WebhooksDispatcher::DispatchResult.ok(200))
      allow(described_class).to receive(:perform_in)

      worker.perform
      expect(described_class).to have_received(:perform_in)
    end

    it 'skips reschedule when explicitly disabled' do
      allow(Outbound::WebhooksDispatcher).to receive(:dispatch)
        .and_return(Outbound::WebhooksDispatcher::DispatchResult.ok(200))
      allow(described_class).to receive(:perform_in)

      worker.perform('reschedule' => false)
      expect(described_class).not_to have_received(:perform_in)
    end
  end
end
