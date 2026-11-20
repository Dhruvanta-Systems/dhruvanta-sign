# frozen_string_literal: true

require 'rails_helper'

# Routing headers (account and user ids, template variables, and for the
# invitation mail the password-reset link) exist only for the HTTP mail API.
# They must not appear on any mail that is delivered over SMTP.
RSpec.describe MailApiRoutingHeadersInterceptor do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account:) }
  let(:invitee) { create(:user, account:, email: 'invitee@example.com') }
  let(:forbidden_headers) { described_class::HEADERS }

  def delivered_header_names(mail)
    mail.header.fields.map(&:name)
  end

  def deliver_via(method, mail_proc)
    ActionMailer::Base.deliveries.clear
    original = UserMailer.delivery_method
    UserMailer.delivery_method = method
    mail_proc.call
  ensure
    UserMailer.delivery_method = original
  end

  describe 'on the SMTP-style path (test delivery stands in for SMTP)' do
    it 'sends the invitation mail, reset link included, with no routing header' do
      UserMailer.invitation_email(invitee, invited_by: admin).deliver_now

      mail = ActionMailer::Base.deliveries.last
      expect(mail.body.encoded).to include('reset_password_token')
      forbidden_headers.each { |name| expect(mail[name]).to be_nil, "#{name} leaked" }
      expect(delivered_header_names(mail).join(' ')).not_to match(/reset_password_token|X-Docuseal|X-Mailer/i)
    end

    it 'sends the settings mail with no routing header' do
      admin
      SettingsMailer.smtp_successful_setup(admin.email).deliver_now

      mail = ActionMailer::Base.deliveries.last
      forbidden_headers.each { |name| expect(mail[name]).to be_nil, "#{name} leaked" }
    end

    it 'sends the password reset mail with no routing header' do
      admin.send_reset_password_instructions

      mail = ActionMailer::Base.deliveries.last
      expect(mail).to be_present
      forbidden_headers.each { |name| expect(mail[name]).to be_nil, "#{name} leaked" }
    end

    it 'keeps the opaque message id used for delivery bookkeeping' do
      UserMailer.invitation_email(invitee, invited_by: admin).deliver_now

      expect(ActionMailer::Base.deliveries.last['X-Message-Uuid']).to be_present
    end
  end

  describe 'on the HTTP mail API path' do
    let(:fake_client) do
      instance_double(Outbound::HttpMailApiClient, send: Outbound::HttpMailApiClient::DeliveryReceipt.new(
        delivery_id: 'd-1', status: 'queued', queued_at: nil
      ))
    end

    before do
      ENV['MAIL_API_ENABLED'] = 'true'
      allow(Outbound::HttpMailApiClient).to receive(:new).and_return(fake_client)
    end

    after { ENV.delete('MAIL_API_ENABLED') }

    it 'still receives the routing data, so the API path keeps working' do
      deliver_via(:http_mail_api, -> { UserMailer.invitation_email(invitee, invited_by: admin).deliver_now })

      expect(fake_client).to have_received(:send) do |args|
        expect(args[:tenant_id]).to eq(account.id.to_s)
        expect(args[:variables]['cta_url']).to include('reset_password_token')
      end
    end

    it 'strips the headers when a mail falls back to SMTP' do
      smtp = instance_double(Outbound::HttpMailApiDeliveryMethod::SmtpFallback)
      sent = nil
      allow(smtp).to receive(:deliver!) { |m| sent = m }
      mail = Mail.new(to: 'a@example.com', from: 'b@example.com', subject: 's', body: 'b')
      forbidden_headers.each { |name| mail[name] = 'secret-value' }
      mail['X-Mailer-Class'] = 'UnknownMailer' # not in the template map, so SMTP fallback

      Outbound::HttpMailApiDeliveryMethod.new(smtp_fallback: smtp).deliver!(mail)

      forbidden_headers.each { |name| expect(sent[name]).to be_nil, "#{name} reached SMTP" }
    end
  end
end
