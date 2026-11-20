# frozen_string_literal: true

# Registers the HTTP mail API ActionMailer delivery method.
#
# The class is always registered; whether it is used is decided at delivery time.
#
#   * MAIL_API_ENABLED unset or false: SMTP (or the environment's own delivery
#     method) stays in force.
#   * MAIL_API_ENABLED=true: ActionMailer's default delivery method becomes
#     `:http_mail_api`. Per-message delivery methods set by
#     `ActionMailerConfigsInterceptor` (for example per-account SMTP) still win,
#     because the interceptor runs before the delivery method is invoked.
#
# Registration happens in `to_prepare` so the autoloader has
# `Outbound::HttpMailApiDeliveryMethod` available when it is resolved.

Rails.application.config.to_prepare do
  ActionMailer::Base.add_delivery_method(
    :http_mail_api,
    Outbound::HttpMailApiDeliveryMethod
  )
end

if ENV.fetch('MAIL_API_ENABLED', 'false').to_s.downcase == 'true'
  Rails.application.config.action_mailer.delivery_method = :http_mail_api
end
