# frozen_string_literal: true

require 'json'

module Extensions
  # ActionMailer delivery method used in hosted mode: EVERY mail, whatever the
  # mailer, goes to the `notifier` port. There is no whitelist, no SMTP fallback
  # and attachments are carried. A failure raises, so a mail is never silently
  # dropped or sent some other way.
  #
  # The port receives one call:
  #
  #   notifier.deliver(channel: :email, to: [..], cc: [..], bcc: [..], from:, reply_to:,
  #                    subject:, html:, text:, template_key: "UserMailer#invitation_email",
  #                    vars: {}, account_id:, message_id:,
  #                    attachments: [{ filename:, content_type:, content:, inline:, content_id: }])
  #
  # `html` and `text` are the fully rendered bodies, so a notifier that has no
  # template for `template_key` can still send the mail.
  class NotifierDeliveryMethod
    attr_reader :settings

    def initialize(settings = {})
      @settings = settings
    end

    def deliver!(mail)
      Extensions.notifier.deliver(**payload(mail))
    end

    private

    def payload(mail)
      {
        channel: :email,
        to: Array(mail.to), cc: Array(mail.cc), bcc: Array(mail.bcc),
        from: mail[:from]&.to_s, reply_to: mail[:reply_to]&.to_s,
        subject: mail.subject.to_s,
        html: html_of(mail), text: text_of(mail),
        template_key: template_key(mail), vars: variables(mail),
        account_id: header(mail, 'X-Docuseal-Account-Id'),
        message_id: header(mail, 'X-Message-Uuid') || mail.message_id,
        attachments: mail.attachments.map { |attachment| attachment_payload(attachment) }
      }
    end

    def html_of(mail)
      mail.html_part&.body&.decoded || (single_part?(mail, 'text/html') ? mail.body.decoded : nil)
    end

    def text_of(mail)
      mail.text_part&.body&.decoded || (single_part?(mail, 'text/plain') ? mail.body.decoded : nil)
    end

    def single_part?(mail, mime_type)
      !mail.multipart? && mail.mime_type == mime_type
    end

    def attachment_payload(attachment)
      {
        filename: attachment.filename, content_type: attachment.mime_type, content: attachment.body.decoded,
        inline: attachment.inline?, content_id: attachment.content_id
      }
    end

    def template_key(mail)
      klass = header(mail, 'X-Mailer-Class')
      action = header(mail, 'X-Mailer-Action')

      klass.present? && action.present? ? "#{klass}##{action}" : nil
    end

    def variables(mail)
      parsed = JSON.parse(header(mail, 'X-Template-Variables').presence || '{}')

      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      {}
    end

    def header(mail, name)
      field = mail[name]

      field.nil? ? nil : field.value.to_s.presence
    end
  end
end
