# frozen_string_literal: true

# The `X-Mailer-*`, `X-Docuseal-*` and `X-Template-Variables` headers exist only
# so that {Outbound::HttpMailApiDeliveryMethod} can route a mail to the HTTP mail
# API. They carry internal account and user ids and, for the invitation mail, the
# password-reset link. Mail transfer agents log headers, so they must never be
# written onto a message that leaves over SMTP.
#
# Registered after {ActionMailerConfigsInterceptor}, which may replace the
# delivery method: by the time this runs, `message.delivery_method` is the final
# one. The headers stay only when that is the HTTP mail API delivery method.
module MailApiRoutingHeadersInterceptor
  HEADERS = %w[
    X-Mailer-Class
    X-Mailer-Action
    X-Docuseal-Account-Id
    X-Docuseal-User-Id
    X-Template-Variables
  ].freeze

  module_function

  def delivering_email(message)
    strip!(message) unless message.delivery_method.is_a?(Outbound::HttpMailApiDeliveryMethod)

    message
  end

  def strip!(message)
    HEADERS.each { |name| message[name] = nil }
  end
end
