# frozen_string_literal: true

module Extensions
  # The default HTTP implementation of the ports, backed by PremiumBridge.
  #
  # Point PREMIUM_SERVICE_URL (and PREMIUM_API_TOKEN, sent as X-Premium-Token) at
  # any server that speaks this small JSON contract, and choose which ports it
  # supplies with EXTENSIONS_HTTP_PORTS (default "plan,event_sink,verification"):
  #
  #   plan          GET  /api/premium/account/:id/plan
  #                      -> { plan, status, features: [], limits: { docs, users, templates, sends }, suspended }
  #   event_sink    POST /api/hooks/:event                    body: the event payload
  #   verification  POST /api/video-kyc/session               body: payload -> Hash
  #                 GET  /api/video-kyc/status/:slug          -> Hash
  #   notifier      POST /api/notifications                   (see Notifier#deliver)
  #   otp           POST /api/otp/send, POST /api/otp/verify  (see OtpProvider)
  #
  # Event names that older servers know under another name are translated on the
  # way out (submitter.completed is sent as form.completed).
  module Http
    EVENT_WIRE_NAMES = { 'submitter.completed' => 'form.completed' }.freeze

    class Plan
      def account_plan(account_id) = PremiumBridge.fetch_plan!(account_id)
    end

    class EventSink
      def emit(event, payload)
        PremiumBridge.notify(EVENT_WIRE_NAMES.fetch(event, event), payload)
      end
    end

    class Verification
      def start(payload) = PremiumBridge.create_video_kyc_session(payload)

      def status(submitter_slug) = PremiumBridge.video_kyc_status(submitter_slug)
    end

    class Notifier
      # Attachments arrive with raw `content` and leave as `content_base64`.
      def deliver(**message)
        attachments = Array(message[:attachments]).map do |attachment|
          attachment.except(:content).merge(content_base64: Base64.strict_encode64(attachment[:content].to_s))
        end

        PremiumBridge.post_strict!('/api/notifications', message.merge(attachments:))
      end
    end

    class OtpProvider
      def send_code(**params) = PremiumBridge.post_strict!('/api/otp/send', params)

      def verify(subject:, code:, purpose:)
        PremiumBridge.post_strict!('/api/otp/verify', { subject:, code:, purpose: })['verified'] == true
      end
    end

    PROVIDERS = {
      plan: Plan, event_sink: EventSink, verification: Verification, notifier: Notifier, otp: OtpProvider
    }.freeze

    @instances = {}

    def self.provider(key)
      @instances[key] ||= PROVIDERS.fetch(key).new
    end
  end
end
