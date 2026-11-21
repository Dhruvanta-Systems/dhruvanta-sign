# frozen_string_literal: true

require 'rails_helper'

describe SignerOtp do
  let(:otp) { Fakes::OtpProvider.new }

  describe 'hosted mode' do
    around { |example| with_env('HOSTED_MODE' => 'true') { example.run } }

    before { Extensions.register(:otp, otp) }

    it 'makes the local one-time code module raise NotConfigured' do
      expect { OtpChallenges.generate('a@example.test:slug', purpose: 'form_email_2fa') }
        .to raise_error(OtpChallenges::NotConfigured)
      expect { OtpChallenges.verify('123456', 'a@example.test:slug', purpose: 'form_email_2fa') }
        .to raise_error(OtpChallenges::NotConfigured)
      expect(OtpChallenge.count).to eq(0)
    end

    it 'checks a code with the otp_provider and nothing else' do
      expect(described_class.verify(Fakes::OtpProvider::CODE, 'a@example.test:slug')).to be(true)
      expect(described_class.verify('000000', 'a@example.test:slug')).to be(false)
      expect(otp.verified.first).to eq(subject: 'a@example.test:slug', code: '123456', purpose: 'form_email_2fa')
    end

    it 'treats a provider that cannot answer as a wrong code' do
      allow(otp).to receive(:verify).and_raise(PremiumBridge::Unavailable)

      expect(described_class.verify('123456', 'a@example.test:slug')).to be(false)
    end

    it 'fails when no otp_provider is configured rather than using the local module' do
      Extensions.unregister(:otp)

      expect(described_class.verify('123456', 'a@example.test:slug')).to be(false)
      expect(OtpChallenge.count).to eq(0)
    end

    it 'has the verification job ask the provider to send the code and send no local mail' do
      user = create(:user)
      template = create(:template, account: user.account, author: user, except_field_types: %w[payment])
      submission = create(:submission, template:, created_by_user: user)
      submitter = create(:submitter, submission:, uuid: SecureRandom.uuid, email: 'signer@example.test')
      allow(SubmitterMailer).to receive(:otp_verification_email)

      SendSubmitterVerificationEmailJob.new.perform('submitter_id' => submitter.id, 'locale' => 'en')

      expect(SubmitterMailer).not_to have_received(:otp_verification_email)
      expect(otp.sent.sole).to include(to: 'signer@example.test', channel: :email, purpose: 'form_email_2fa',
                                       subject: "signer@example.test:#{submitter.slug}")
      expect(OtpChallenge.count).to eq(0)
    end
  end

  describe 'stock mode' do
    it 'keeps the local one-time codes' do
      code = OtpChallenges.generate('a@example.test:slug', purpose: 'form_email_2fa')

      expect(described_class.provider?).to be(false)
      expect(described_class.verify(code, 'a@example.test:slug')).to be(true)
    end
  end

  describe 'an otp_provider outside hosted mode' do
    it 'is used when registered' do
      Extensions.register(:otp, otp)

      expect(described_class.provider?).to be(true)
      expect(described_class.verify('123456', 'subject')).to be(true)
    end
  end
end
