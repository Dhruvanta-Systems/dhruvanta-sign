# frozen_string_literal: true

# == Schema Information
#
# Table name: account_invitations
#
#  id                 :bigint           not null, primary key
#  accepted_at        :datetime
#  email              :string           not null
#  expires_at         :datetime         not null
#  role               :string           not null
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  account_id         :bigint           not null
#  accepted_user_id   :bigint
#  invited_by_user_id :bigint
#
# Indexes
#
#  index_account_invitations_on_account_id          (account_id)
#  index_account_invitations_on_email_pending       (email) UNIQUE WHERE (accepted_at IS NULL)
#  index_account_invitations_on_invited_by_user_id  (invited_by_user_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (invited_by_user_id => users.id)
#
# An invitation to join an account, used with AUTH_MODE=external. There is no token
# and no link to follow: the invitation is matched by email when that email signs in
# through the identity provider AND the provider asserts the address is verified
# (see JwtSso::HandoffService). It is used once and expires.
class AccountInvitation < ApplicationRecord
  DEFAULT_TTL_DAYS = 7
  ROLES = [User::ADMIN_ROLE, User::EDITOR_ROLE, User::VIEWER_ROLE].freeze

  belongs_to :account
  belongs_to :invited_by_user, class_name: 'User', optional: true

  normalizes :email, with: ->(value) { value.to_s.strip.downcase }

  validates :email, presence: true, format: { with: User::VALIDATE_EMAIL_REGEXP }
  validates :role, inclusion: { in: ROLES }
  validate :email_not_taken, on: :create

  before_validation { self.expires_at ||= self.class.ttl.from_now }

  scope :pending, -> { where(accepted_at: nil).where(expires_at: Time.current..) }

  def self.ttl
    days = ENV.fetch('INVITATION_TTL_DAYS', nil).to_s
    (days.match?(/\A[1-9]\d*\z/) ? days.to_i : DEFAULT_TTL_DAYS).days
  end

  # Creates the invitation, replacing an earlier unused one for the same email
  # (so re-inviting renews it).
  def self.invite!(account:, email:, role:, invited_by: nil)
    transaction do
      where(email: email.to_s.strip.downcase, accepted_at: nil).delete_all

      create!(account:, email:, role:, invited_by_user: invited_by)
    end
  end

  # Joins `email` to the inviting account: the user is created with the invited
  # role and the invitation is used up, in one transaction. Returns the user, or
  # nil when there is no pending invitation. The row is locked so two sign-ins
  # cannot both use it.
  def self.accept!(email:, first_name:, last_name:, **identity)
    user = nil

    transaction do
      invitation = pending.lock.find_by(email: email.to_s.strip.downcase)

      if invitation
        user = User.create!(account: invitation.account, email: invitation.email, first_name:, last_name:,
                            password: SecureRandom.hex(32), role: invitation.role, **identity)
        invitation.update!(accepted_at: Time.current, accepted_user_id: user.id)
      end
    end

    user
  end

  def expired?
    expires_at <= Time.current
  end

  private

  def email_not_taken
    errors.add(:email, :taken) if User.exists?(email:)
  end
end
