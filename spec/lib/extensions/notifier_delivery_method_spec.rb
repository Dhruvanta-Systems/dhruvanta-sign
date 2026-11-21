# frozen_string_literal: true

require 'rails_helper'

# Hosted mode: every mail goes to the notifier. No whitelist, no SMTP fallback,
# attachments carried.
describe Extensions::NotifierDeliveryMethod do
  let(:notifier) { Fakes::Notifier.new }

  before { Extensions.register(:notifier, notifier) }

  around do |example|
    original = ActionMailer::Base.delivery_method
    ActionMailer::Base.delivery_method = :extension_notifier

    with_env('HOSTED_MODE' => 'true') { example.run }
  ensure
    ActionMailer::Base.delivery_method = original
  end

  it 'is registered as a delivery method' do
    expect(ActionMailer::Base.delivery_methods[:extension_notifier]).to eq(described_class)
  end

  it 'sends a mail that the HTTP mail API whitelist would have refused, with its attachment' do
    mail = Mail.new(from: 'sender@example.test', to: 'signer@example.test', subject: 'Your signed copy')
    mail.text_part = Mail::Part.new(body: 'plain body')
    mail.html_part = Mail::Part.new(content_type: 'text/html; charset=UTF-8', body: '<p>html body</p>')
    mail.attachments['signed.pdf'] = { mime_type: 'application/pdf', content: '%PDF-fake' }
    mail['X-Mailer-Class'] = 'SubmitterMailer'
    mail['X-Mailer-Action'] = 'completed_email'

    described_class.new.deliver!(mail)

    sent = notifier.deliveries.sole
    expect(sent).to include(channel: :email, to: ['signer@example.test'], subject: 'Your signed copy',
                            template_key: 'SubmitterMailer#completed_email')
    expect(sent[:html]).to include('html body')
    expect(sent[:text]).to include('plain body')
    expect(sent[:attachments]).to contain_exactly(
      hash_including(filename: 'signed.pdf', content_type: 'application/pdf', content: '%PDF-fake')
    )
  end

  it 'carries template variables and the account when the mailer set them' do
    mail = Mail.new(to: 'a@example.test', subject: 's', body: 'b')
    mail['X-Docuseal-Account-Id'] = '42'
    mail['X-Template-Variables'] = '{"link":"https://sign.example.test/x"}'

    described_class.new.deliver!(mail)

    expect(notifier.deliveries.sole).to include(account_id: '42', vars: { 'link' => 'https://sign.example.test/x' })
  end

  it 'raises when the notifier fails: a mail is never dropped silently or sent another way' do
    notifier.fail_with = StandardError.new('notifier down')
    mail = Mail.new(to: 'a@example.test', subject: 's', body: 'b')

    expect { described_class.new.deliver!(mail) }.to raise_error(StandardError, 'notifier down')
  end

  it 'raises when no notifier is configured instead of falling back to SMTP' do
    Extensions.unregister(:notifier)

    expect { described_class.new.deliver!(Mail.new(to: 'a@example.test', subject: 's', body: 'b')) }
      .to raise_error(Extensions::NotConfigured)
  end

  describe 'through the real mailers' do
    let(:user) { create(:user) }

    it 'sends a user invitation mail (a whitelisted one in the HTTP mail API) to the notifier' do
      UserMailer.invitation_email(user).deliver_now!

      expect(notifier.deliveries.sole).to include(to: [user.email], template_key: 'UserMailer#invitation_email')
    end

    it 'sends a mail the HTTP mail API never routed (not whitelisted) to the notifier' do
      template = create(:template, account: user.account, author: user, except_field_types: %w[payment])
      submission = create(:submission, :with_submitters, template:,
                                                         created_by_user: user)

      SubmitterMailer.invitation_email(submission.submitters.first).deliver_now!

      expect(notifier.deliveries.sole).to include(template_key: 'SubmitterMailer#invitation_email')
    end

    it 'never opens an SMTP connection' do
      allow(Net::SMTP).to receive(:start).and_raise('SMTP must not be used')
      allow(Net::SMTP).to receive(:new).and_raise('SMTP must not be used')

      UserMailer.invitation_email(user).deliver_now!

      expect(notifier.deliveries.size).to eq(1)
    end

    it 'does not apply per-account SMTP settings or the SMTP_FROM sender' do
      create(:encrypted_config, key: EncryptedConfig::EMAIL_SMTP_KEY, account: user.account,
                                value: { 'host' => 'smtp.example.test', 'port' => 587, 'from_email' => 'x@example.test' })
      allow(Rails.env).to receive(:production?).and_return(true)
      mail = UserMailer.invitation_email(user)

      ActionMailerConfigsInterceptor.delivering_email(mail.message)

      expect(mail.message.delivery_method).to be_a(described_class)
      expect(mail.message.from.to_s).not_to include('x@example.test')
    end

    it 'keeps the routing headers for the notifier only: they are not left on the message after delivery routing' do
      mail = UserMailer.invitation_email(user)

      MailApiRoutingHeadersInterceptor.delivering_email(mail.message)

      expect(mail.message['X-Mailer-Class']).to be_present
    end
  end
end
