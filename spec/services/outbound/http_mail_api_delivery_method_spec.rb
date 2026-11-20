# frozen_string_literal: true

require 'rails_helper'

# Coverage for Outbound::HttpMailApiDeliveryMethod: routing to the mail API versus the SMTP fallback.
RSpec.describe Outbound::HttpMailApiDeliveryMethod do
  let(:fake_client) do
    instance_double(Outbound::HttpMailApiClient).tap do |c|
      allow(c).to receive(:send).and_return(
        Outbound::HttpMailApiClient::DeliveryReceipt.new(
          delivery_id: 'd-1', status: 'queued', queued_at: nil
        )
      )
    end
  end
  let(:client_factory) { -> { fake_client } }
  let(:smtp_fallback)  { instance_double(described_class::SmtpFallback, deliver!: nil) }

  before { ENV['MAIL_API_ENABLED'] = 'true' }
  after  { ENV.delete('MAIL_API_ENABLED') }

  def build_mail(headers: {}, attachments: [], to: 'jane@example.com')
    mail = Mail.new
    mail.to = to
    mail.from = 'from@example.com'
    mail.subject = 'hello'
    mail.body = '<p>hello</p>'
    headers.each { |k, v| mail[k] = v }
    attachments.each { |a| mail.add_file(filename: a[:filename], content: a[:content]) }
    mail
  end

  def subject_with(stubbed_smtp: true)
    settings = { client_factory: client_factory }
    settings[:smtp_fallback] = smtp_fallback if stubbed_smtp
    described_class.new(settings)
  end

  describe '#deliver!' do
    it 'routes to mail API on a registered template + tenant' do
      mail = build_mail(headers: {
                          'X-Mailer-Class' => 'UserMailer',
                          'X-Mailer-Action' => 'invitation_email',
                          'X-Docuseal-Account-Id' => 'acc-42',
                          'X-Template-Variables' => '{"product_name":"DocuSeal"}',
                          'X-Message-Uuid' => 'msg-uuid-1'
                        })

      subject_with.deliver!(mail)

      expect(fake_client).to have_received(:send).with(
        hash_including(
          template_key: 'user_invitation',
          recipient: 'jane@example.com',
          tenant_id: 'acc-42',
          idempotency_key: 'msg-uuid-1'
        )
      )
      expect(smtp_fallback).not_to have_received(:deliver!)
    end

    it 'falls back to SMTP when the flag is off' do
      ENV['MAIL_API_ENABLED'] = 'false'
      mail = build_mail(headers: {
                          'X-Mailer-Class' => 'UserMailer',
                          'X-Mailer-Action' => 'invitation_email',
                          'X-Docuseal-Account-Id' => 'acc-42'
                        })

      subject_with.deliver!(mail)

      expect(smtp_fallback).to have_received(:deliver!).with(mail)
      expect(fake_client).not_to have_received(:send)
    end

    it 'falls back to SMTP when the template_key is unknown' do
      mail = build_mail(headers: {
                          'X-Mailer-Class' => 'SomeUnknownMailer',
                          'X-Mailer-Action' => 'random_action',
                          'X-Docuseal-Account-Id' => 'acc-42'
                        })

      subject_with.deliver!(mail)

      expect(smtp_fallback).to have_received(:deliver!).with(mail)
      expect(fake_client).not_to have_received(:send)
    end

    it 'falls back to SMTP when there are attachments (structural mismatch)' do
      mail = build_mail(
        headers: {
          'X-Mailer-Class' => 'UserMailer',
          'X-Mailer-Action' => 'invitation_email',
          'X-Docuseal-Account-Id' => 'acc-42'
        },
        attachments: [{ filename: 'doc.pdf', content: 'PDF-DATA' }]
      )

      subject_with.deliver!(mail)

      expect(smtp_fallback).to have_received(:deliver!).with(mail)
      expect(fake_client).not_to have_received(:send)
    end

    it 'falls back to SMTP when the X-Docuseal-Account-Id header is missing' do
      mail = build_mail(headers: {
                          'X-Mailer-Class' => 'UserMailer',
                          'X-Mailer-Action' => 'invitation_email'
                        })

      subject_with.deliver!(mail)

      expect(smtp_fallback).to have_received(:deliver!).with(mail)
      expect(fake_client).not_to have_received(:send)
    end

    it 'falls back to SMTP and logs when an internal error occurs in translation' do
      bad_factory = -> { raise StandardError, 'translation kaboom' }
      mail = build_mail(headers: {
                          'X-Mailer-Class' => 'UserMailer',
                          'X-Mailer-Action' => 'invitation_email',
                          'X-Docuseal-Account-Id' => 'acc-42'
                        })
      bad_subject = described_class.new(
        client_factory: bad_factory,
        smtp_fallback: smtp_fallback,
        logger: double('Logger', info: nil, warn: nil, error: nil)
      )

      bad_subject.deliver!(mail)

      expect(smtp_fallback).to have_received(:deliver!).with(mail)
    end

    it 'lets EmailDeliveryError propagate (does NOT silently fall back)' do
      allow(fake_client).to receive(:send).and_raise(
        Outbound::HttpMailApiClient::EmailDeliveryError, 'wire failure'
      )
      mail = build_mail(headers: {
                          'X-Mailer-Class' => 'UserMailer',
                          'X-Mailer-Action' => 'invitation_email',
                          'X-Docuseal-Account-Id' => 'acc-42'
                        })

      expect { subject_with.deliver!(mail) }.to raise_error(
        Outbound::HttpMailApiClient::EmailDeliveryError
      )
      expect(smtp_fallback).not_to have_received(:deliver!)
    end

    it 'parses X-Template-Variables JSON into the variables hash' do
      mail = build_mail(headers: {
                          'X-Mailer-Class' => 'UserMailer',
                          'X-Mailer-Action' => 'invitation_email',
                          'X-Docuseal-Account-Id' => 'acc-42',
                          'X-Template-Variables' => '{"first_name":"Jane","cta_url":"https://x.test/y"}'
                        })

      subject_with.deliver!(mail)

      expect(fake_client).to have_received(:send).with(
        hash_including(variables: { 'first_name' => 'Jane', 'cta_url' => 'https://x.test/y' })
      )
    end

    it 'tolerates malformed X-Template-Variables JSON (sends empty hash)' do
      mail = build_mail(headers: {
                          'X-Mailer-Class' => 'UserMailer',
                          'X-Mailer-Action' => 'invitation_email',
                          'X-Docuseal-Account-Id' => 'acc-42',
                          'X-Template-Variables' => '{not-json'
                        })

      subject_with.deliver!(mail)

      expect(fake_client).to have_received(:send).with(hash_including(variables: {}))
    end

    it 'emits a structured router-decision audit on every deliver! call' do
      logger = double('Logger', info: nil, warn: nil, error: nil)
      mail = build_mail(headers: {
                          'X-Mailer-Class' => 'UserMailer',
                          'X-Mailer-Action' => 'invitation_email',
                          'X-Docuseal-Account-Id' => 'acc-42'
                        })
      subject = described_class.new(
        client_factory: client_factory,
        smtp_fallback: smtp_fallback,
        logger: logger
      )

      subject.deliver!(mail)

      expect(logger).to have_received(:info).with(a_string_starting_with('audit.delivery_method_router '))
    end
  end
end
