# frozen_string_literal: true

require 'json'

class ApplicationMailer < ActionMailer::Base
  default from: 'DocuSeal <info@docuseal.com>'
  layout 'mailer'

  register_interceptor ActionMailerConfigsInterceptor
  register_interceptor HtmlToPlainTextInterceptor
  register_preview_interceptor HtmlToPlainTextInterceptor

  register_observer ActionMailerEventsObserver

  before_action do
    ActiveStorage::Current.url_options = Docuseal.default_url_options
  end

  after_action :set_message_metadata
  after_action :set_message_uuid
  after_action :set_mail_api_routing_headers

  def default_url_options
    Docuseal.default_url_options.merge(host: ENV.fetch('EMAIL_HOST', Docuseal.default_url_options[:host]))
  end

  def set_message_metadata
    message.instance_variable_set(:@message_metadata, @message_metadata || {})
  end

  def set_message_uuid
    message['X-Message-Uuid'] = SecureRandom.uuid
  end

  # Routing headers read by `Outbound::HttpMailApiDeliveryMethod` to decide
  # whether to send a mail through the HTTP mail API or SMTP. Set on every mail,
  # whatever the mailer class; the delivery method is the gate. Concrete mailers
  # may call {#set_mail_api_template_variables} to add the account, user and
  # template variables. This hook only fills `X-Mailer-Class` and
  # `X-Mailer-Action` and is idempotent.
  def set_mail_api_routing_headers
    message['X-Mailer-Class']  = self.class.name
    message['X-Mailer-Action'] = action_name.to_s
  end

  # Helper for concrete mailers to fill the mail API routing data:
  #
  #   * `X-Docuseal-Account-Id` is required for routing (tenant scoping); when
  #     it is missing the delivery method falls back to SMTP.
  #   * `X-Docuseal-User-Id` is the acting user id (nil for system origins).
  #   * `X-Template-Variables` is a JSON object of merge variables for the
  #     mail API template.
  #
  # Mailers without a registered template key need not call this; the delivery
  # method falls back to SMTP for unknown templates by design.
  def set_mail_api_template_variables(account_id:, user_id: nil, variables: {})
    message['X-Docuseal-Account-Id'] = account_id.to_s if account_id
    message['X-Docuseal-User-Id']    = user_id.to_s    unless user_id.nil? || user_id.to_s.empty?
    message['X-Template-Variables']  = JSON.generate(variables.is_a?(Hash) ? variables : {})
  rescue StandardError => e
    # A header failure must never block the originating flow; the delivery
    # method falls back to SMTP when the tenant id is missing.
    Rails.logger.warn("[application-mailer] set_mail_api_template_variables failed: #{e.message}")
  end

  def assign_message_metadata(tag, record)
    @message_metadata = (@message_metadata || {}).merge(
      'tag' => tag,
      'record_id' => record.id,
      'record_type' => record.class.name
    )
  end

  def put_metadata(attrs)
    @message_metadata = (@message_metadata || {}).merge(attrs)
  end
end
