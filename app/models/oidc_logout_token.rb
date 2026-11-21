# frozen_string_literal: true

# == Schema Information
#
# Table name: oidc_logout_tokens
#
#  id         :bigint           not null, primary key
#  expires_at :datetime         not null
#  issuer     :string           not null
#  jti        :string           not null
#  created_at :datetime         not null
#
# Back-channel logout tokens that were accepted. A `jti` is accepted once; the table
# is shared by every app process (never a per-process cache).
class OidcLogoutToken < ApplicationRecord
  RETENTION = 1.hour

  # @return [Boolean] true the first time (issuer, jti) is seen
  def self.claim!(issuer:, jti:)
    where(expires_at: ...Time.current).delete_all
    create!(issuer:, jti:, expires_at: RETENTION.from_now, created_at: Time.current)

    true
  rescue ActiveRecord::RecordNotUnique
    false
  end
end
