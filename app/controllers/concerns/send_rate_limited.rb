# frozen_string_literal: true

# Per-account and per-IP burst limits on the actions that create submissions or
# send messages (see Extensions::Gate.rate_limit!). Off unless hosted mode or
# ABUSE_CONTROLS=true; a refusal raises RateLimit::LimitApproached, which the
# base controllers already turn into "Too many requests" (429 for the API).
module SendRateLimited
  extend ActiveSupport::Concern

  private

  def enforce_send_rate_limit!
    enforce_send_rate_limit_for!(current_user&.account)
  end

  def enforce_send_rate_limit_for!(account)
    return if account.nil?

    Extensions::Gate.rate_limit!(account:, ip: request.remote_ip)
  end
end
