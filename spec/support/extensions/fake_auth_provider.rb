# frozen_string_literal: true

# Reference fake of the auth_provider port: what the sign-in handoff asks of it.
#
#   verify_handoff(token, expected_nonce:) -> handoff (responds to subject, email,
#       email_verified, display_name, tenant_id, tier, jti)
#   lookup_or_provision_user(handoff) -> User
#   audit_received(handoff, user, ip:, user_agent:)
#   audit_failed(code, ip:, user_agent:)
#
# A provider reports a refused token by raising JwtSso::HandoffService::HandoffError.
module Fakes
  class AuthProvider
    Handoff = Struct.new(:jti, :subject, :tenant_id, :audience, :email, :email_verified, :display_name, :tier,
                         :expires_at, keyword_init: true)

    attr_reader :received, :failed

    def initialize(email: 'fake-user@example.test')
      @email = email
      @received = []
      @failed = []
    end

    def verify_handoff(token, expected_nonce:)
      raise JwtSso::HandoffService::HandoffError, 'sso-handoff-signature-invalid' unless token == "token-for-#{expected_nonce}"

      Handoff.new(jti: SecureRandom.uuid, subject: 'fake-subject', email: @email, email_verified: true,
                  display_name: 'Fake User')
    end

    def lookup_or_provision_user(handoff)
      User.find_by(email: handoff.email) || begin
        account = Account.create!(name: handoff.display_name, locale: 'en-US', timezone: 'UTC')
        User.create!(account:, email: handoff.email, first_name: 'Fake', last_name: 'User',
                     password: SecureRandom.hex(32), role: User::ADMIN_ROLE)
      end
    end

    def audit_received(handoff, user, **)
      @received << [handoff, user]
    end

    def audit_failed(code, **)
      @failed << code
    end
  end
end
