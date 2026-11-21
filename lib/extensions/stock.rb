# frozen_string_literal: true

module Extensions
  # The default for every port when nothing is registered and the HTTP service
  # is not enabled for it. These keep the app behaving like upstream: no plan
  # limits, no events, local sign-in, local one-time codes and local storage.
  module Stock
    class Plan
      # An install with no plan provider has no plans: every account is on a
      # plan with no features and no limits (upstream behaviour).
      def account_plan(_account_id)
        { plan: 'free', status: 'active', features: [], limits: {}, suspended: false }
      end
    end

    class Auth
      # The generic JWT handoff receiver (see JwtSso::HandoffService).
      def verify_handoff(token, expected_nonce:)
        service.verify_handoff(token, expected_nonce:)
      end

      delegate :lookup_or_provision_user, to: :service

      def audit_received(*, **)
        service.audit_received(*, **)
      end

      def audit_failed(*, **)
        service.audit_failed(*, **)
      end

      private

      # A fresh service per call, as before the port existed (it holds no state
      # between calls).
      def service
        JwtSso::HandoffService.new
      end
    end

    class Notifier
      def deliver(**)
        raise NotConfigured, 'no notifier is configured'
      end
    end

    class OtpProvider
      def send_code(**)
        raise NotConfigured, 'no otp_provider is configured'
      end

      def verify(**)
        raise NotConfigured, 'no otp_provider is configured'
      end
    end

    class Storage
      def name
        Rails.application.config.active_storage.service
      end
    end

    class EventSink
      def emit(_event, _payload); end
    end

    class Verification
      def start(_payload) = {}

      def status(_submitter_slug) = { 'status' => 'not_started' }
    end

    class PaymentStep
      def create(*, **)
        raise NotConfigured, 'no payment_step_provider is configured'
      end

      def status(*, **)
        raise NotConfigured, 'no payment_step_provider is configured'
      end
    end

    PROVIDERS = {
      auth: Auth, notifier: Notifier, otp: OtpProvider, plan: Plan, storage: Storage,
      event_sink: EventSink, verification: Verification, payment_step: PaymentStep
    }.freeze

    @instances = {}

    def self.provider(key)
      @instances[key] ||= PROVIDERS.fetch(key).new
    end
  end
end
