# frozen_string_literal: true

# == Schema Information
#
# Table name: oidc_sessions
#
#  id           :bigint           not null, primary key
#  acr          :string
#  amr          :string           default([]), not null, is an Array
#  auth_time    :datetime
#  expires_at   :datetime         not null
#  issuer       :string           not null
#  revoked_at   :datetime
#  sid          :string
#  sub          :string           not null
#  token_digest :string           not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  user_id      :bigint           not null
#
# The server-side session registry: one row per sign-in through the OpenID Connect
# provider, keyed by the provider's session id (`sid`). The browser holds only a
# random token (its SHA-256 is `token_digest`). A revoked or expired row ends the
# session on the next request.
class OidcSession < ApplicationRecord
  belongs_to :user

  scope :active, -> { where(revoked_at: nil).where(expires_at: Time.current..) }

  # Creates the row and returns [row, token]; the token goes into the browser session.
  def self.open!(user:, issuer:, sub:, sid:, auth_time:, acr:, amr:)
    token = SecureRandom.urlsafe_base64(32)
    row = create!(user:, issuer:, sub:, sid:, token_digest: digest(token), acr:, amr: Array(amr).map(&:to_s),
                  auth_time: auth_time && Time.zone.at(auth_time.to_i),
                  expires_at: Oidc::Config.session_max_age.seconds.from_now)

    [row, token]
  end

  def self.digest(token)
    Digest::SHA256.hexdigest(token.to_s)
  end

  def self.for_token(token)
    return if token.blank?

    active.find_by(token_digest: digest(token))
  end

  # Back-channel logout: every active session of the provider session `sid`, or, when
  # the provider names only the person, every active session of that subject.
  def self.revoke_for!(issuer:, sid: nil, sub: nil)
    scope = active.where(issuer:)
    scope = sid.present? ? scope.where(sid:) : scope.where(sub:)

    scope.update_all(revoked_at: Time.current, updated_at: Time.current)
  end

  def revoke!
    update!(revoked_at: Time.current) unless revoked_at
  end
end
