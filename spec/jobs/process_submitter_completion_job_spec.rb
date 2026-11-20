# frozen_string_literal: true

RSpec.describe ProcessSubmitterCompletionJob do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:template) { create(:template, account:, author: user) }
  let(:submission) { create(:submission, template:, created_by_user: user) }
  let(:submitter) { create(:submitter, submission:, uuid: SecureRandom.uuid, completed_at: Time.current) }

  before do
    create(:encrypted_config, key: EncryptedConfig::ESIGN_CERTS_KEY,
                              value: GenerateCertificate.call.transform_values(&:to_pem))

    Submissions.maybe_update_completed_at(submitter.submission)
  end

  describe '#perform' do
    it 'creates a completed submitter' do
      expect do
        described_class.new.perform('submitter_id' => submitter.id)
      end.to change(CompletedSubmitter, :count).by(1)

      completed_submitter = CompletedSubmitter.last
      submitter.reload

      expect(completed_submitter.submitter_id).to eq(submitter.id)
      expect(completed_submitter.submission_id).to eq(submitter.submission_id)
      expect(completed_submitter.account_id).to eq(submitter.submission.account_id)
      expect(completed_submitter.template_id).to eq(submitter.submission.template_id)
      expect(completed_submitter.source).to eq(submitter.submission.source)
    end

    it 'creates a completed document' do
      expect do
        described_class.new.perform('submitter_id' => submitter.id)
      end.to change(CompletedDocument, :count).by(1)

      completed_document = CompletedDocument.last

      expect(completed_document.submitter_id).to eq(submitter.id)
      expect(completed_document.sha256).to be_present
      expect(completed_document.sha256).to eq(submitter.documents.first.metadata['sha256'])
    end

    it 'raises an error if the submitter is not found' do
      expect do
        described_class.new.perform('submitter_id' => 'invalid_id')
      end.to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  describe '#enqueue_event_webhooks' do
    it 'adds event type and external scope to signed and completed payloads' do
      external_tenant_id = SecureRandom.uuid
      external_user_id = SecureRandom.uuid
      create(:account_config, account:, key: AccountConfig::EXTERNAL_TENANT_ID_KEY, value: external_tenant_id)
      create(:user_config, user:, key: UserConfig::EXTERNAL_USER_ID_KEY, value: external_user_id)

      described_class.new.enqueue_event_webhooks(submitter, is_last: true)

      signed = JSON.parse(WebhookOutbox.find_by!(event_type: WebhookOutbox::EVENT_SUBMITTER_SIGNED).payload)
      completed = JSON.parse(WebhookOutbox.find_by!(event_type: WebhookOutbox::EVENT_SUBMISSION_COMPLETED).payload)

      expect(signed).to include(
        'event_type' => 'submitter_signed',
        'external_tenant_id' => external_tenant_id,
        'external_user_id' => external_user_id
      )
      expect(completed).to include(
        'event_type' => 'submission_completed',
        'external_tenant_id' => external_tenant_id,
        'external_user_id' => external_user_id
      )
    end
  end
end
