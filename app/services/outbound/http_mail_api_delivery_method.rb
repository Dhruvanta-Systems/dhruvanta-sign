# frozen_string_literal: true

require 'securerandom'

module Outbound
  # ActionMailer delivery method that sends a small whitelist of transactional
  # mails through a generic HTTP mail API ({Outbound::HttpMailApiClient}) and
  # everything else through SMTP.
  #
  # It is off unless MAIL_API_ENABLED=true; while off, every mail goes through
  # SMTP exactly as if this class were not registered.
  #
  # A mail is routed to the API only when all of these hold:
  #
  #   1. its `(mailer_class, action_name)` is in {DEFAULT_TEMPLATE_KEY_MAP} (extend or
  #      replace it with a JSON object in MAIL_API_TEMPLATE_KEYS, e.g.
  #      {"UserMailer#invitation_email":"user_invitation"}),
  #   2. it has no attachments (the API has no attachment slot),
  #   3. it carries an `X-Docuseal-Account-Id` header, set by `ApplicationMailer`
  #      and sent as the tenant id, and
  #   4. `Docuseal.demo?` is false.
  #
  # Anything else falls back to SMTP via {SmtpFallback}. Mailers whose subject and
  # body are customised per account are deliberately not whitelisted.
  #
  # Per-template variables are read from the JSON `X-Template-Variables` header.
  # Any extraction error is logged and falls back to SMTP, which is the safety
  # net. A wire error from the API itself is NOT retried over SMTP, so an API
  # outage is not masked.
  #
  # Routing decisions are logged as `audit.delivery_method_router` lines.
  class HttpMailApiDeliveryMethod
    # `(mailer_class, action_name)` → mail API template key.
    # Conservative whitelist per advisor guidance — mailers with
    # account-customizable bodies / attachment-bearing payloads
    # are deliberately omitted.
    DEFAULT_TEMPLATE_KEY_MAP = {
      'UserMailer#invitation_email' => 'user_invitation',
      'SettingsMailer#smtp_successful_setup' => 'smtp_setup_confirmation',
      'SubmitterMailer#expiry_warning_email' => 'submission_expiry_warning'
    }.freeze

    FALLBACK_REASON_FLAG_OFF        = 'flag_off'
    FALLBACK_REASON_DEMO_MODE       = 'demo_mode'
    FALLBACK_REASON_UNKNOWN_TEMPLATE = 'unknown_template'
    FALLBACK_REASON_HAS_ATTACHMENTS  = 'has_attachments'
    FALLBACK_REASON_MISSING_TENANT   = 'missing_tenant'
    FALLBACK_REASON_INTERNAL_ERROR   = 'internal_error'

    attr_reader :settings

    def initialize(settings = {})
      @settings = settings
      @client_factory = settings[:client_factory] || -> { Outbound::HttpMailApiClient.new }
      @smtp_fallback  = settings[:smtp_fallback]  || SmtpFallback.new(settings)
      @logger         = settings[:logger]         || Rails.logger
    end

    # The Rails delivery-method protocol entrypoint. Mail::SMTP, etc.
    # all implement `deliver!(mail)`.
    def deliver!(mail)
      decision = decide(mail)
      if decision[:route] == :http_mail_api
        emit_router_audit('ROUTED', mail, template_key: decision[:template_key])
        send_via_mail_api(mail, decision)
      else
        emit_router_audit('FALLBACK', mail, reason: decision[:reason])
        deliver_over_smtp(mail)
      end
    rescue Outbound::HttpMailApiClient::EmailDeliveryError => e
      # Fail-closed wire error — DO NOT silently retry through SMTP
      # (would mask mail API outages). Surface to ActionMailer
      # which respects `raise_delivery_errors`.
      @logger&.error("[mail-api-delivery] failed mail_id=#{mail.message_id} reason=#{e.message}")
      raise
    rescue StandardError => e
      # Anything else — translation bug, JSON encode failure, etc. —
      # fall back to SMTP rather than 4xx the originating flow.
      @logger&.warn(
        "[mail-api-delivery] internal-error fallback mail_id=#{mail.message_id} " \
        "reason=#{e.class.name}: #{e.message}"
      )
      emit_router_audit('FALLBACK', mail, reason: FALLBACK_REASON_INTERNAL_ERROR)
      deliver_over_smtp(mail)
    end

    private

    # Routing headers hold internal ids and the invitation's reset link; they are
    # for this class only and must not go out in an SMTP message.
    def deliver_over_smtp(mail)
      MailApiRoutingHeadersInterceptor.strip!(mail)
      @smtp_fallback.deliver!(mail)
    end

    def decide(mail)
      return { route: :smtp, reason: FALLBACK_REASON_FLAG_OFF } unless flag_enabled?
      if defined?(Docuseal) && Docuseal.respond_to?(:demo?) && Docuseal.demo?
        return { route: :smtp, reason: FALLBACK_REASON_DEMO_MODE }
      end
      return { route: :smtp, reason: FALLBACK_REASON_HAS_ATTACHMENTS } if mail.attachments.any?

      template_key = lookup_template_key(mail)
      return { route: :smtp, reason: FALLBACK_REASON_UNKNOWN_TEMPLATE } if template_key.nil?

      tenant_id = extract_header(mail, 'X-Docuseal-Account-Id')
      return { route: :smtp, reason: FALLBACK_REASON_MISSING_TENANT } if blank?(tenant_id)

      { route: :http_mail_api, template_key: template_key, tenant_id: tenant_id }
    end

    def send_via_mail_api(mail, decision)
      recipient = Array(mail.to).first.to_s
      variables = extract_variables(mail)
      idempotency_key = extract_header(mail, 'X-Message-Uuid') || SecureRandom.uuid
      user_id = extract_header(mail, 'X-Docuseal-User-Id')

      client = @client_factory.call
      client.send(
        template_key: decision[:template_key],
        recipient: recipient,
        variables: variables,
        tenant_id: decision[:tenant_id],
        user_id: user_id,
        idempotency_key: idempotency_key
      )
    end

    def lookup_template_key(mail)
      mailer_class = extract_header(mail, 'X-Mailer-Class')
      action_name  = extract_header(mail, 'X-Mailer-Action')
      return nil if blank?(mailer_class) || blank?(action_name)

      template_key_map["#{mailer_class}##{action_name}"]
    end

    def extract_variables(mail)
      raw = extract_header(mail, 'X-Template-Variables')
      return {} if blank?(raw)

      parsed = JSON.parse(raw.to_s)
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      {}
    end

    def extract_header(mail, name)
      header = mail[name]
      return nil if header.nil?

      header.respond_to?(:value) ? header.value.to_s : header.to_s
    end

    def template_key_map
      raw = ENV['MAIL_API_TEMPLATE_KEYS'].to_s.strip
      return DEFAULT_TEMPLATE_KEY_MAP if raw.empty?

      parsed = JSON.parse(raw)
      parsed.is_a?(Hash) ? parsed : DEFAULT_TEMPLATE_KEY_MAP
    rescue JSON::ParserError
      DEFAULT_TEMPLATE_KEY_MAP
    end

    def flag_enabled?
      ENV.fetch('MAIL_API_ENABLED', 'false').to_s.downcase == 'true'
    end

    def emit_router_audit(outcome, mail, template_key: nil, reason: nil)
      event = {
        event_code: 'EMAIL_DELIVERY_ROUTER_DECISION',
        actor_user_id: extract_header(mail, 'X-Docuseal-User-Id'),
        target_id_type: 'EMAIL_DELIVERY',
        target_id_hash: nil,
        provider_ref: extract_header(mail, 'X-Message-Uuid'),
        verified_at: Time.now.utc.iso8601,
        failure_reason: reason,
        emitted_at: Time.now.utc.iso8601,
        outcome: outcome,
        template_key: template_key,
        mailer_class: extract_header(mail, 'X-Mailer-Class'),
        mailer_action: extract_header(mail, 'X-Mailer-Action')
      }
      @logger&.info("audit.delivery_method_router #{JSON.generate(event)}")
    rescue StandardError => e
      @logger&.warn("[delivery-method-router-audit] failed reason=#{e.message}")
    end

    def blank?(value)
      value.nil? || value.to_s.strip.empty?
    end

    # SMTP fallback: delegates to `Mail::SMTP` configured via the
    # `:settings` hash that Rails passes to delivery methods. We
    # match Rails' built-in SMTP delivery method behaviour: build a
    # fresh `Mail::SMTP` per delivery and call `deliver!` on it. The
    # interceptor (`ActionMailerConfigsInterceptor`) has already
    # rewritten `message.delivery_method` to per-account SMTP at this
    # point, so we MUST honor the message's chosen delivery method
    # if it differs from this one — otherwise we'd shortcut the
    # interceptor's per-account routing.
    class SmtpFallback
      def initialize(settings = {})
        @settings = settings
      end

      def deliver!(mail)
        # If the interceptor has installed a per-account delivery method
        # on the message itself (e.g. via `message.delivery_method(:smtp,
        # smtp_settings)` in `ActionMailerConfigsInterceptor`), the
        # message-level method wins and our fallback should be a no-op
        # — Mail will dispatch via the message's own method when
        # `deliver!` is invoked again. To preserve the interceptor
        # contract we hand off via Mail::SMTP only when no per-message
        # method is set.
        if mail.respond_to?(:delivery_method) && mail.delivery_method.is_a?(Mail::SMTP)
          mail.delivery_method.deliver!(mail)
        else
          Mail::SMTP.new(@settings).deliver!(mail)
        end
      end
    end
  end
end
