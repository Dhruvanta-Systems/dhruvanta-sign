# frozen_string_literal: true

require 'rails_helper'

# Unit coverage for Outbound::SubmissionWebhookEmitter.
RSpec.describe Outbound::SubmissionWebhookEmitter do
  let(:account)  { create(:account) }
  let(:user)     { create(:user, account:) }
  let(:template) { create(:template, account:, author: user) }

  before do
    # Drain-worker stubbed at the dispatcher boundary so the spec
    # asserts on outbox-row creation, not on Faraday wire calls.
    allow(Outbound::WebhooksDispatcher).to receive(:dispatch)
      .and_return(Outbound::WebhooksDispatcher::DispatchResult.ok(200))
  end

  describe '.emit' do
    it 'creates exactly one pending outbox row for the submission' do
      create(:submission, :with_submitters, template:, created_by_user: user)

      rows = WebhookOutbox.where(event_type: WebhookOutbox::EVENT_SUBMISSION_CREATED)
      expect(rows.count).to eq(1)
      expect(rows.first).to be_pending
      expect(rows.first.target_aud).to eq(WebhookOutbox::TARGET_DEFAULT)
    end

    it 'is idempotent on a re-emit against the same submission (single row)' do
      submission = create(:submission, :with_submitters, template:, created_by_user: user)

      # Second explicit call — UNIQUE on delivery_id de-dupes to a
      # single row.
      described_class.emit(submission)
      described_class.emit(submission)

      rows = WebhookOutbox.where(event_type: WebhookOutbox::EVENT_SUBMISSION_CREATED)
      expect(rows.count).to eq(1)
    end

    it 'builds an outbox payload with event type, legacy keys, and external scope' do
      external_tenant_id = SecureRandom.uuid
      external_user_id = SecureRandom.uuid
      create(:account_config, account:, key: AccountConfig::EXTERNAL_TENANT_ID_KEY, value: external_tenant_id)
      create(:user_config, user:, key: UserConfig::EXTERNAL_USER_ID_KEY, value: external_user_id)

      submission = create(:submission, :with_submitters, template:, created_by_user: user, source: 'api')

      row = WebhookOutbox.where(event_type: WebhookOutbox::EVENT_SUBMISSION_CREATED).first
      payload = JSON.parse(row.payload)

      expect(payload['event_type']).to eq('submission_created')
      expect(payload['submission_id']).to eq(submission.id)
      expect(payload['account_id']).to    eq(submission.account_id)
      expect(payload['template_id']).to   eq(submission.template_id)
      expect(payload['source']).to        eq('api')
      expect(payload['submitter_count']).to eq(template.submitters.size)
      expect(payload['submitter_count']).to eq(submission.submitters.size)
      expect(payload['submitter_count']).to be >= 1
      expect(payload['created_at']).to match(/\AT?[0-9-]+T[0-9:]+/)
      expect(payload['external_tenant_id']).to eq(external_tenant_id)
      expect(payload['external_user_id']).to eq(external_user_id)
    end

    it 'keeps external scope keys present with nil values when the account was not provisioned by SSO' do
      create(:submission, :with_submitters, template:, created_by_user: user)

      row = WebhookOutbox.where(event_type: WebhookOutbox::EVENT_SUBMISSION_CREATED).first
      payload = JSON.parse(row.payload)

      expect(payload).to include('external_tenant_id' => nil, 'external_user_id' => nil)
    end

    it 'swallows dispatcher exceptions (failure-additive contract)' do
      allow(Outbound::WebhooksDispatcher).to receive(:enqueue_submission_created)
        .and_raise(StandardError, 'simulated outbox failure')

      submission = build(:submission, template:, account:, created_by_user: user)
      submission.account_id = account.id
      submission.template_fields = template.fields
      submission.template_schema = template.schema
      submission.template_submitters = template.submitters

      # The save! path runs the after_commit which calls .emit; the
      # exception must NOT propagate out (would 500 the controller).
      expect { submission.save! }.not_to raise_error
    end

    it 'attaches via after_commit (not after_create) — row visible from a fresh connection' do
      callback = Submission._commit_callbacks.find do |cb|
        cb.filter == :emit_submission_created_webhook
      end

      expect(callback).not_to be_nil
      # `on: :create` → kind is :create on after_commit
      expect(callback.kind).to eq(:after)
      expect(Submission._create_callbacks.find do |cb|
        cb.filter == :emit_submission_created_webhook
      end).to be_nil
    end

    it 'returns nil when called with nil (defensive)' do
      expect(described_class.emit(nil)).to be_nil
    end

    it 'returns nil when called on an unpersisted record' do
      submission = Submission.new
      expect(described_class.emit(submission)).to be_nil
      expect(WebhookOutbox.count).to eq(0)
    end
  end
end
