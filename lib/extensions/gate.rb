# frozen_string_literal: true

module Extensions
  # Checks made BEFORE something that costs us money is done: creating a
  # submission, sending an invitation, a reminder or a text message.
  #
  #   Gate.check_create!(account, count: 1)   a submission is about to be created
  #   Gate.check_send!(account)               a message is about to go out
  #   Gate.rate_limit!(account:, ip:)         per-account and per-IP burst limits
  #
  # Quotas and the suspend switch come from the plan provider, so with no plan
  # provider nothing is limited. The rate limits are on in hosted mode (or with
  # ABUSE_CONTROLS=true) and are shared by every app process through the Redis that
  # Sidekiq uses (see RateLimit::Shared); in hosted mode a store that is down refuses.
  module Gate
    RATE_WINDOW = 10.minutes
    DEFAULT_ACCOUNT_LIMIT = 60
    DEFAULT_IP_LIMIT = 120

    module_function

    def check_create!(account, count: 1)
      return unless Extensions.configured?(:plan)

      ensure_usable!(account)
      raise_unless_within!(account, :docs, count)
    end

    # A new member or template is about to be created (or an archived one brought back).
    # `key` is :users or :templates.
    def check_resource!(account, key)
      return unless Extensions.configured?(:plan)

      ensure_usable!(account)
      raise_unless_within!(account, key, 1)
    end

    def check_send!(account)
      return unless Extensions.configured?(:plan)

      ensure_usable!(account)
      raise_unless_within!(account, :sends, 1)
    end

    # check_send! for callers that skip instead of raising (background jobs).
    def send_allowed?(account)
      check_send!(account)
      true
    rescue GateError => e
      Rails.logger.warn("Extensions::Gate refused a send for account #{account.id}: #{e.class}")
      false
    end

    # Raises RateLimit::LimitApproached when the account or the address has done
    # too much in the window.
    def rate_limit!(account:, ip:)
      return true unless Extensions.abuse_controls?

      account_id = account.respond_to?(:id) ? account.id : account

      RateLimit::Shared.call("abuse-account-#{account_id}",
                             limit: limit_from_env('RATE_LIMIT_ACCOUNT', DEFAULT_ACCOUNT_LIMIT), ttl: RATE_WINDOW)
      RateLimit::Shared.call("abuse-ip-#{ip}",
                             limit: limit_from_env('RATE_LIMIT_IP', DEFAULT_IP_LIMIT), ttl: RATE_WINDOW)
    end

    def ensure_usable!(account)
      plan = Extensions.plan_for(account)

      raise PlanUnavailable if plan.unavailable?
      raise AccountSuspended if plan.suspended?
    end

    def raise_unless_within!(account, key, add)
      return if Extensions.within_limit?(account, key, add:)

      raise LimitExceeded.new(key, Extensions.plan_for(account).limit(key))
    end

    def limit_from_env(name, default)
      value = ENV.fetch(name, nil).to_s.strip

      value.match?(/\A[1-9]\d*\z/) ? value.to_i : default
    end
  end
end
