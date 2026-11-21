# frozen_string_literal: true

# One-time codes for signers (email 2FA to open a form). In hosted mode, or when an
# otp_provider is configured, the provider generates, sends and checks the code;
# otherwise the local OtpChallenges module does (stock behaviour).
module SignerOtp
  PURPOSE = 'form_email_2fa'

  module_function

  def provider?
    Extensions.hosted? || Extensions.configured?(:otp)
  end

  # @return [Boolean] whether the code is right
  def verify(code, subject, purpose: PURPOSE)
    return OtpChallenges.verify(code, subject, purpose:) unless provider?

    Extensions.otp.verify(subject:, code:, purpose:) == true
  rescue Extensions::NotConfigured, PremiumBridge::Unavailable => e
    Rails.logger.warn("SignerOtp verify failed: #{e.class}")
    false
  end

  # Has the provider send a fresh code to `to`. Only for provider mode; the local
  # module sends its code from a mailer.
  def send_code(subject, to:, locale: nil, account_id: nil, purpose: PURPOSE)
    Extensions.otp.send_code(subject:, purpose:, channel: :email, to:, locale: locale&.to_s, account_id:)
  end
end
