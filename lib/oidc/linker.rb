# frozen_string_literal: true

module Oidc
  # Finds the local user for a verified id_token, or provisions one.
  #
  # A person is identified ONLY by the provider's stable (issuer, sub), stored on the
  # user. An email address is never an identifier:
  #
  #   1. a user bound to this (issuer, sub) is that person, whatever address they
  #      have now; when the provider reports a new, free address the user follows it;
  #   2. otherwise a PENDING invitation for the verified address joins the inviting
  #      account, once, and the new user is bound to (issuer, sub);
  #   3. otherwise a new account is created, but only when sign-up is allowed
  #      (OIDC_ALLOW_SIGNUP);
  #   4. an address that already belongs to a user bound to ANOTHER subject (a
  #      recycled or taken-over address) never reaches that user: the sign-in is refused.
  module Linker
    module_function

    # @param claims [Hash] a verified id_token (email_verified is true)
    # @return [User]
    def call(claims)
      identity = { sso_issuer: Config.issuer, sso_subject: claims['sub'].to_s }
      email = claims['email'].to_s.strip.downcase
      raise Error, 'invalid_email' unless email.match?(User::VALIDATE_EMAIL_REGEXP)

      user = User.find_by(identity) || join_or_provision(claims, identity, email)
      follow_email_change(user, email)
      ExternalScopeStore.persist!(account: user.account, user:, tenant_id: nil, external_user_id: claims['sub'])

      user
    rescue ActiveRecord::RecordNotUnique
      # Two sign-ins of the same new person at once: the second finds the first's user.
      User.find_by!(identity)
    end

    def join_or_provision(claims, identity, email)
      raise Error.new('email_bound', :conflict, 'This email address belongs to another account.') if User.exists?(email:)

      first_name, last_name = split_name(claims['name'].presence || claims['given_name'], claims)
      AccountInvitation.accept!(email:, first_name:, last_name:, **identity) ||
        provision(identity, email, first_name, last_name, claims)
    end

    def provision(identity, email, first_name, last_name, claims)
      raise Error.new('signup_closed', :forbidden, 'Sign-up is closed.') unless Config.allow_signup?

      ActiveRecord::Base.transaction do
        account = Account.create!(name: claims['name'].presence || email.split('@').first, locale: 'en-US', timezone: 'UTC')

        User.create!(account:, email:, first_name:, last_name:, password: SecureRandom.hex(32),
                     role: User::ADMIN_ROLE, **identity)
      end
    end

    # The provider reported a new verified address for a known person: keep the
    # user's address in step when it is free, so the old address can be given to
    # someone else without reaching this account.
    def follow_email_change(user, email)
      user.update!(email:) if user.email != email && !User.exists?(email:)
    end

    def split_name(name, claims)
      return [claims['given_name'], claims['family_name']] if claims['given_name'].present? && claims['family_name'].present?

      parts = name.to_s.strip.split(/\s+/, 2)
      [parts[0], parts[1]]
    end
  end
end
