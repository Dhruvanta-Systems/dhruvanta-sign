# frozen_string_literal: true

RSpec.describe ProcessSubmitterCompletionJob, 'premium service notification' do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:template) { create(:template, account:, author: user) }
  let(:submission) { create(:submission, template:, created_by_user: user) }
  let(:submitter) { create(:submitter, submission:, uuid: SecureRandom.uuid, completed_at: Time.current) }

  before do
    create(:encrypted_config, key: EncryptedConfig::ESIGN_CERTS_KEY,
                              value: GenerateCertificate.call.transform_values(&:to_pem))
    Submissions.maybe_update_completed_at(submission)
    allow(PremiumBridge).to receive(:enabled?).and_return(true)
    allow(PremiumBridge).to receive(:notify)
  end

  it 'sends form.completed and submission.completed for the last submitter' do
    described_class.new.perform('submitter_id' => submitter.id)

    expect(PremiumBridge).to have_received(:notify).with('form.completed', hash_including(submitter_id: submitter.id))
    expect(PremiumBridge).to have_received(:notify).with('submission.completed', hash_including(submission_id: submission.id))
  end

  it 'does not send submission.completed when others have yet to sign' do
    described_class.new.perform('submitter_id' => submitter.id, 'is_last' => false)

    expect(PremiumBridge).to have_received(:notify).with('form.completed', anything)
    expect(PremiumBridge).not_to have_received(:notify).with('submission.completed', anything)
  end

  it 'never fails the job when the service is unreachable' do
    allow(PremiumBridge).to receive(:notify).and_raise(StandardError, 'boom')

    expect { described_class.new.perform('submitter_id' => submitter.id) }.not_to raise_error
  end
end
