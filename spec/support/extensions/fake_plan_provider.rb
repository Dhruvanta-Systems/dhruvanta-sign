# frozen_string_literal: true

# Reference fake of the plan_provider port (see Extensions).
#
#   account_plan(account_id) -> { plan:, status:, features:, limits:, suspended: }
#
# `limits` keys: docs, users, templates, sends (per calendar month for docs and
# sends); a missing or nil key is unlimited. Set `fail_with` to make the provider
# raise, to exercise outage handling.
module Fakes
  class PlanProvider
    DEFAULT_PLAN = {
      plan: 'free', status: 'active', features: [], limits: { docs: 10, sends: 20 }, suspended: false
    }.freeze

    attr_accessor :fail_with
    attr_reader :calls

    def initialize(default: DEFAULT_PLAN, plans: {})
      @default = default
      @plans = plans
      @calls = []
    end

    def set(account_id, plan)
      @plans[account_id] = plan
    end

    def account_plan(account_id)
      @calls << account_id
      raise fail_with if fail_with

      @plans.fetch(account_id, @default)
    end
  end
end
