# frozen_string_literal: true

module Extensions
  # The fail-closed profile. With HOSTED_MODE=true the app refuses to boot unless
  # every capability that a hosted service must supply itself is in place and
  # every built-in that would bypass them is switched off:
  #
  #   * the auth, notifier, otp, plan and storage ports are configured;
  #   * no local sign-in route is drawn (sessions, passwords, invitations, setup,
  #     two-factor setup, password reset) - set AUTH_MODE=external;
  #   * SMTP delivery is not configured (SMTP_ADDRESS) and mail goes to the notifier;
  #   * the Active Storage service is not the local disk.
  #
  # `violations` is pure (everything it looks at is passed in) so each rule can be
  # tested by planting its violation.
  module HostedBoot
    class Error < StandardError; end

    REQUIRED_PORTS = %i[auth notifier otp plan storage].freeze

    # Controllers that serve local sign-in, password, invitation, setup and
    # two-factor flows. A route to any of them is a local auth route.
    LOCAL_AUTH_CONTROLLERS = %w[
      sessions passwords invitations setup mfa_setup users_send_reset_password
    ].freeze

    # Paths and actions of local auth that live inside a controller serving other things.
    LOCAL_AUTH_ACTIONS = { 'profile' => %w[update_password] }.freeze

    module_function

    # @param routes [Enumerable<#defaults>] the drawn routes
    # @param smtp_settings [Object] the Rails SMTP settings (config.action_mailer.smtp_settings)
    # @return [Array<String>] one sentence per violation
    def violations(env:, routes:, delivery_method:, smtp_settings:, storage_name:, configured:)
      list = []

      missing = REQUIRED_PORTS.reject { |port| configured.call(port) }
      list << "missing extensions: #{missing.join(', ')}" if missing.any?

      local = local_auth_routes(routes)
      list << "local auth routes are drawn (#{local.first(4).join(', ')}); set AUTH_MODE=external" if local.any?

      if env['SMTP_ADDRESS'].to_s.strip.present? || smtp_settings.present? || delivery_method.to_s == 'smtp'
        list << 'SMTP delivery is configured; hosted mode sends all mail through the notifier'
      elsif delivery_method.to_s != 'extension_notifier'
        list << "mail delivery method is #{delivery_method.inspect}, expected the notifier"
      end

      list << 'storage is :disk; hosted mode needs an object store' if storage_name.to_s.in?(%w[disk local])

      list
    end

    def local_auth_routes(routes)
      routes.filter_map do |route|
        controller = route.defaults[:controller].to_s
        action = route.defaults[:action].to_s

        next unless LOCAL_AUTH_CONTROLLERS.include?(controller) || LOCAL_AUTH_ACTIONS[controller]&.include?(action)

        "#{controller}##{action}"
      end
    end

    def verify!(app = Rails.application)
      app.reload_routes_unless_loaded if app.respond_to?(:reload_routes_unless_loaded)

      found = violations(
        env: ENV, routes: app.routes.routes, delivery_method: ActionMailer::Base.delivery_method,
        smtp_settings: app.config.action_mailer.smtp_settings,
        storage_name: Extensions.storage_service_name,
        configured: ->(port) { Extensions.configured?(port) }
      )

      raise Error, "HOSTED_MODE refuses to start:\n- #{found.join("\n- ")}" if found.any?

      true
    end
  end
end
